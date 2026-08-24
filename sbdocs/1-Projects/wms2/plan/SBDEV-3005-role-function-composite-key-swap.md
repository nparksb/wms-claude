---
title: "WMSv2: a function cannot be added to a role — the role↔function composite key is built with its components reversed, and the non-atomic save wipes existing assignments"
ticket: "SBDEV-3005"
ticket_url: "https://app.clickup.com/t/868ku70j5"
type: "bugfix"
priority: "high"
status: "pr submitted 2026-08-19 — wms2-api PR #170 (commit f4e78c5) into develop, rebased onto 6135203. Fixes A-F plus review fixes M2/M3/L4. Verify: 39 pass, 0 fail, 2 skip. Gate classes 72/72 green; full suite 5164 tests, 2 pre-existing unrelated failures. Reviewed by two independent lanes; Fix D is a set difference, Fix F added. Reviewed by TWO code-review lanes after implementation; all High/Medium fixed and mutation-verified. Manual tests NOT run (M4/M8 are the only end-to-end evidence for AC-5 and AC-13); P2 prd audit still open; H1 ungated-write recorded as a follow-up. One open prerequisite: P2, the prd wh01_hydra_v2 audit."
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-19
updated: 2026-08-19
db_verified: true
related:
  - SBDEV-3011-delete-role-join-table-cascade.md
  - SBDEV-2967-web-ui-function-gating-enforcement.md
  - SBDEV-2968-mobile-ui-function-gating-enforcement.md
  - SBDEV-2870-ungated-user-admin-and-damaged-lock-endpoints.md
  - ../../../3-Resources/architecture/wms2-keycloak-role-matrix.md
  - ../../../3-Resources/architecture/wms2-transaction-osiv-boundary-map.md
tags:
  - plan
---

# WMSv2: a function cannot be added to a role — the role↔function composite key is built with its components reversed

**Ticket:** [SBDEV-3005](https://app.clickup.com/t/868ku70j5)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high
**Status:** reviewed 2026-08-19 — ready to implement; P2 open
**Date:** 2026-08-19

---

## 0. Affected sites (enumeration before drafting)

Enumerated by grepping every construction site of all five `@Embeddable` composite-id records in `net.aim_ai.wms.model`, not from memory:

```bash
grep -rln "@Embeddable" src/main/java/net/aim_ai/wms/model/     # → 5 records
for r in ShippingmethodShipperidId UserUserRoleId UserGroupUserId \
         UserRoleUserFunctionId UserGroupUserRoleId; do
  grep -rn "new $r(" src/main/java src/test/java
done
```

Result: **6 production construction sites across 5 records.** Exactly one record is constructed with its components reversed.

**Two sites this axis structurally cannot see** were surfaced by an independent review lane and are added as rows 13–14. Enumerating *construction sites of the composite-id records* finds every WRITE through the `UserRoleUserFunction` entity, but it is blind to (a) repository READS that pass the wrong column, and (b) a `@ManyToMany @JoinTable` mapping the same table without going through the entity at all. Both were missed on the first pass; the axis, not the diligence, was the limit.

| # | File:line | Construct | Declared component order | Passed | Same root cause? | In scope? |
|---|-----------|-----------|--------------------------|--------|------------------|-----------|
| 1 | `controller/UserRoleController.java:98` | `new UserRoleUserFunctionId(functionId, roleId)` | `(rolelistId, functionlistId)` | **reversed** | **yes — the reported bug** | **yes — Fix A** |
| 2 | `service/UserFunctionService.java:51` | `new UserRoleUserFunctionId(functionId, roleId)` | `(rolelistId, functionlistId)` | **reversed** | **yes** | **yes — Fix B** |
| 3 | `service/AccessService.java:146` | `addRoleToFunction(function.getId(), connector_role.getId())` | `addRoleToFunction(roleId, functionId)` | **reversed at the call site** | **yes — cancels #2** | **yes — Fix C (mandatory paired change)** |
| 4 | `service/UserGroupService.java:81` | `new UserGroupUserId(groupId, userId)` | `(grouplistId, userlistId)` | correct | no | no — correct as written |
| 5 | `controller/UserController.java:327` | `new UserGroupUserId(groupId, userId)` | `(grouplistId, userlistId)` | correct | no | no — correct as written |
| 6 | `service/UserRoleService.java:88` | `new UserGroupUserRoleId(groupId, roleId)` | `(grouplistId, rolelistId)` | correct | no | no — correct as written |
| 7 | `controller/UserGroupController.java:111` | `new UserGroupUserRoleId(groupId, roleId)` | `(grouplistId, rolelistId)` | correct | no | no — correct as written |
| 8 | `controller/UserRoleController.java:85-104` | `saveRoleFunctions` deletes then inserts with no transaction | — | — | **secondary defect** | **yes — Fix D** |
| 9 | `controller/UserRoleController.java:87` | `LOG.info("delete printer with Id {}", reqMap.get("printerId"))` | — | copy-paste from `PrinterController` | cosmetic, same method | **yes — Fix E** |
| 10 | `controller/UserGroupController.java:99-117` | `saveGroupRoles` — same non-atomic delete-then-insert | — | — | same pattern as #8, orientation OK | **deferred — §12.2** |
| 11 | `controller/UserController.java:310-334` | `saveUserGroups` — same non-atomic delete-then-insert | — | — | same pattern as #8, orientation OK | **deferred — §12.2** |
| 12 | `model/UserUserRoleId.java`, `model/ShippingmethodShipperidId.java` | records exist, **zero** production construction sites (test-only) | — | — | no | no — nothing to break |
| 13 | `service/AccessService.java:256` and `:284` | `findByFunctionlistId(role.getId())` — a ROLE id queried against the `functionlist_id` column | — | **wrong column** | **yes — same orientation confusion, on the READ side** | **yes — Fix F (latent)** |
| 14 | `model/UserRole.java:27-33` | `@ManyToMany(fetch = EAGER, cascade = PERSIST) @JoinTable(name = "mywms_role_mywms_function")` — a **second, independent mapping of the same table** | joinColumns `rolelist_id`, inverse `functionlist_id` | correct | no | no — correct by construction, but see §11 and §5 Fix D |
| 15 | `controller/UserRoleController.java:71-82` | `deletRole` clears `mywms_role_mywms_function` but not `mywms_group_mywms_role` / `mywms_user_mywms_role`, which also FK to `mywms_role(id)` | — | — | different bug, same method family | **deferred — §12.2** |

**Why rows 4–7 are safe and row 1–2 are not** — see §3 The Regression Chain. This is not luck that needs re-checking each time; it has a specific, verified cause.

---

## 1. Problem Statement

An administrator cannot grant any function to any role. In the WMS2 web UI, Admin → User Management → Roles → edit a role's functions → Save returns HTTP 500.

Reported against tenant `wine-wsl`: created a role named `test role`, tried to add `WEB_UI_LOG_IN`.

```
INFO  n.a.w.controller.UserRoleController - [wine-wsl][] delete printer with Id null
ERROR o.h.e.jdbc.spi.SqlExceptionHelper - [wine-wsl][] ERROR: insert or update on table
  "mywms_role_mywms_function" violates foreign key constraint "fkby47oyt3v45jq6sysqya4til9"
  Detail: Key (rolelist_id)=(51700) is not present in table "mywms_role".
[insert into mywms_role_mywms_function (rolelist_id,functionlist_id) values (?,?)]
→ org.springframework.dao.DataIntegrityViolationException
```

Two things are wrong, and only the first is visible:

1. **The insert always violates the FK.** `51700` is the id of the *function* `WEB_UI_LOG_IN`, not a role id. The role id was written into the other column.
2. **The failed save silently destroys existing state.** The endpoint deletes the role's current function rows before inserting the new set, in separate committed transactions. The deletes commit; the insert then fails. A role that previously had functions is left with **zero**. `test role` was empty so nothing was lost, but doing this to `super-admin` strips it.

### Reproduction

1. Any v2 tenant, any role.
2. `POST /v3/userRole/saveRoleFunctions` with `{"roleId": <any real role id>, "functions": [<any real function id>]}`.
3. → HTTP 500, `DataIntegrityViolationException`. Re-read the role's functions: they are now empty.

### DB verification (analysis protocol §8 — `db_verified: true`)

Confirmed on `wsl-wineco-uat` that the reported id is a function, not a role:

```sql
SELECT id, name FROM mywms_function WHERE id BETWEEN 51690 AND 51720;
-- → {id: 51700, name: 'WEB_UI_LOG_IN'}   ← the value that landed in rolelist_id

SELECT min(id), max(id) FROM mywms_role;      -- → 51800 .. 821840800  (no 51700)
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
  WHERE conrelid = 'mywms_role_mywms_function'::regclass;
-- → mywms_role_mywms_function_pkey  PRIMARY KEY (rolelist_id, functionlist_id)
-- → fkby47oyt3v45jq6sysqya4til9     FOREIGN KEY (rolelist_id) REFERENCES mywms_role(id)
-- → fkgewu6gt6lnpo19dlhqmtkrhgs     FOREIGN KEY (functionlist_id) REFERENCES mywms_function(id)
```

Pre-existing rows are correctly oriented (`rolelist_id=51800, functionlist_id=51700`), because they were seeded by the migration base dump — **not** written through this endpoint. This code path has never worked since it was introduced (§3).

---

## 2. Root Cause Analysis

### Bug 1 — the composite key's components are passed in reverse (the 500)

`model/UserRoleUserFunctionId.java:9` declares the order **role first, function second**:

```java
@Embeddable
public record UserRoleUserFunctionId (
    @Column(name = "rolelist_id",     nullable = false) Long rolelistId,
    @Column(name = "functionlist_id", nullable = false) Long functionlistId
) implements Serializable {}
```

Both writers pass them the other way round.

`controller/UserRoleController.java:97-101`:
```java
functionIds.forEach(functionId -> {
    UserRoleUserFunctionId compositId =
        new UserRoleUserFunctionId(Long.valueOf(functionId), Long.valueOf(roleId));  // ← reversed
    UserRoleUserFunction roleFunction = new UserRoleUserFunction(compositId);
    userRoleUserFunctionRepository.save(roleFunction);
});
```

`service/UserFunctionService.java:48-54`:
```java
public void addRoleToFunction(Long roleId, Long functionId) {
    Optional<UserRoleUserFunction> roleFunctionOpt =
        userRoleUserFunctionRepository.findByRolelistIdAndFunctionlistId(roleId, functionId);  // ← correct
    if (!roleFunctionOpt.isPresent()) {
        UserRoleUserFunctionId compositId = new UserRoleUserFunctionId(functionId, roleId);    // ← reversed
        UserRoleUserFunction roleFunction = new UserRoleUserFunction(compositId);
        userRoleUserFunctionRepository.save(roleFunction);
    }
}
```

Note that within this one method the **read is correctly oriented and the write is not**. The guard therefore never matches what the insert produces, so the guard cannot short-circuit and the insert is always attempted.

The function id lands in `rolelist_id`, where FK `fkby47oyt3v45jq6sysqya4til9` requires a `mywms_role.id` → `DataIntegrityViolationException` → HTTP 500.

**Failure mode depends on the tenant's id ranges.** Because `rolelist_id` and `functionlist_id` are both plain `bigint` FKs, a swapped write is only *rejected* when the function id is absent from `mywms_role`. On a tenant where a function id coincides with a role id, the swapped row would **commit successfully and grant the wrong function to the wrong role** — a silent authorization misgrant instead of a loud 500. §5.1-P1 records the audit that shows this has not yet happened, and why it is a live risk rather than a theoretical one.

### Bug 2 — `saveRoleFunctions` is not atomic (the data loss)

```java
// UserRoleController.java:85-104 — no @Transactional on the method,
// and none on the class or on its base AdminController (grep count: 0)
List<UserRoleUserFunction> roleFunctions =
    userRoleUserFunctionRepository.findByRolelistId(Long.valueOf(roleId));
roleFunctions.forEach(roleFunction -> {
    userRoleUserFunctionRepository.delete(roleFunction);   // ← each commits on its own
});
functionIds.forEach(functionId -> { ... save(...); });     // ← first one throws
```

With no surrounding transaction, each `SimpleJpaRepository.delete()` runs in its own `REQUIRED` transaction and commits immediately. OSIV is disabled (`spring.jpa.open-in-view=false`), so nothing holds these together. The deletes are durable before the first insert is attempted.

`findByRolelistId(roleId)` is correctly oriented, so it finds and deletes the role's **real** rows. The net effect of one failed save is that the role loses every function it had.

This defect is independent of Bug 1: even after Bug 1 is fixed, a partial failure mid-loop (a stale function id, a PK collision from a duplicate id in the request list, a connection drop) would leave the role with a truncated function set and no error path back.

### Bug 3 — misleading log line (cosmetic, but it is what operators see first)

`UserRoleController.java:87` is the first line of `saveRoleFunctions`:

```java
LOG.info("delete printer with Id {}", reqMap.get("printerId"));   // reqMap has no "printerId" → null
```

Copy-pasted from `PrinterController` (the same string appears at `PrinterController.java:144,173`, `UserGroupController.java:82`, `UserRoleController.java:73`). This is the `delete printer with Id null` line that precedes every occurrence of this stack trace and sends whoever reads the log looking at printer code. `UserRoleController.java:102` has the matching problem — it logs `"Role with Id {} is deleted"` on the success path of a *save*.

---

## 3. The Regression Chain

| Commit | Date | What it did |
|--------|------|-------------|
| `4676fa5c` | — | `updated user role, group, function services` — original setter-based code, correct |
| **`5442a06a`** | **2025-12-23** | **`update repositories to remove getNextId() ... and some entity object to have compound key consistently; all the changes are required by Spring Boot 3.5 upgrade`** — converted `@IdClass` + setters to `@EmbeddedId` + a positional `record`, and rewrote the call sites. **This is where the swap was introduced.** |
| `9a68b625`, `c066b56e`, `4a083b58`, `e75260f9` | — | package moves, constructor injection, SLF4J, i18n — carried the defect forward untouched |

The mechanism is precise and worth recording, because it explains why exactly one of the five records is affected. Before `5442a06a` the write used **named setters**, and in this file the setter lines happened to be written function-first:

```java
// before 5442a06a — order of the lines is irrelevant, the names bind the values
UserRoleUserFunction roleFunction = new UserRoleUserFunction();
roleFunction.setFunctionlistId(Long.valueOf(functionId));
roleFunction.setRolelistId(Long.valueOf(roleId));
```

The conversion preserved the **textual order of the setter lines** rather than the record's component order:

```java
// after 5442a06a — positional, so line order became argument order
UserRoleUserFunctionId compositId =
    new UserRoleUserFunctionId(Long.valueOf(functionId), Long.valueOf(roleId));
```

The three sibling join tables were converted by the same mechanical rule in the same commit, but their setter lines were written group-first:

```java
groupRole.setGrouplistId(groupId);      →  new UserGroupUserRoleId(groupId, Long.valueOf(roleId));
groupRole.setRolelistId(...);              // matches (grouplistId, rolelistId) — accidentally correct
```

So they match their record's declared order and are genuinely safe. **`UserRoleUserFunctionId` was the only record whose pre-conversion setter lines ran in the opposite order to its component declaration** — hence one victim out of five, and hence rows 4–7 of §0 needing no change.

Verify with:
```bash
git show 5442a06a -- src/main/java/net/aim_ai/wms/controller/UserRoleController.java \
                     src/main/java/net/aim_ai/wms/service/UserFunctionService.java
```

---

## 4. Architecture Overview

```
Web UI: components/admin/userManagement/roles/roleFunctionEdit.vue:93
   dispatch('admin/role/saveRoleFunctions', { roleId: role.id, functions: itemsInEdit })
        │
        ▼  store/admin/role.js:70   POST /userRole/saveRoleFunctions
┌──────────────────────────────────────────────────────────────────────┐
│ UserRoleController.saveRoleFunctions          (:85)  ← no @Transactional
│   ├─ LOG "delete printer with Id null"        (:87)  ← Bug 3
│   ├─ findByRolelistId(roleId)                 (:92)  ← correct orientation
│   ├─ delete(each)                             (:94)  ← Bug 2: each commits
│   └─ new UserRoleUserFunctionId(fn, role)     (:98)  ← Bug 1: reversed  ✗ 500
└──────────────────────────────────────────────────────────────────────┘

Second, independent live path into the same defect:
┌──────────────────────────────────────────────────────────────────────┐
│ POST /rest/util/initAdmin  (UtilRestController:874)
│   └─ AccessService.addFunctionToUser          (:89)
│        ├─ groupService.addUserToGroup                    ✓
│        ├─ roleService.addGroupToRole                     ✓
│        └─ userFunctionService.addRoleToFunction (:102)
│             └─ new UserRoleUserFunctionId(fn, role) (:51) ← Bug 1  ✗ 500
└──────────────────────────────────────────────────────────────────────┘
```

### Key files

| File | Lines | Role |
|------|-------|------|
| `model/UserRoleUserFunctionId.java` | 9-15 | The record. Declares `(rolelistId, functionlistId)`. **Do not reorder it** — see §3 and §12.1 |
| `model/UserRoleUserFunction.java` | 22-58 | `@EmbeddedId` entity over `mywms_role_mywms_function` |
| `controller/UserRoleController.java` | 85-104 | `saveRoleFunctions` — Bugs 1, 2, 3 |
| `service/UserFunctionService.java` | 48-54 | `addRoleToFunction` — Bug 1, read/write orientation disagree |
| `service/AccessService.java` | 89-103, 126-128, 137-148 | `addFunctionToUser` / `addFunctionToRole` / `addFunctionToGroup` — the callers; `:146` is reversed at the call site |
| `service/UserRoleService.java` | 85-117 | Already injected into the controller; has **no** `@Transactional` anywhere. Fix D's new home |
| `controller/rest/UtilRestController.java` | 874-888 | `/initAdmin` — live second path into Bug 1 |
| `common/base/BaseControllerUnitTest.java` | 49-56 | `MockMvcBuilders.standaloneSetup` — no Spring context, so **no transaction proxy** (§6 constraint) |

### Caller matrix for `addRoleToFunction` — the landmine

`AccessService` reaches `addRoleToFunction(roleId, functionId)` from three methods, and **one of them passes its arguments reversed**, which cancels the reversed record construction and produces correct rows today:

| Caller | Passes | Effective `rolelist_id` | Today |
|---|---|---|---|
| `AccessService:102` `addFunctionToUser` | `(role, func)` — matches signature | `func` | **broken** (FK violation) |
| `AccessService:127` `addFunctionToRole` | `(role, func)` — matches signature | `func` | **broken** (FK violation) |
| `AccessService:146` `addFunctionToGroup` | `(func, role)` — **reversed** | `role` | **accidentally correct** |

**Fixing `UserFunctionService:51` alone silently breaks `addFunctionToGroup`.** Fix B and Fix C are one atomic change; neither may land without the other.

### Reachability of each broken path

| Path | Reachable? | In scope |
|---|---|---|
| `UserRoleController.saveRoleFunctions` | **Live** — the web UI role editor. **The only live broken write path.** The reported bug | **yes** |
| `POST /rest/util/initAdmin` → `addFunctionToUser` (`UtilRestController:882,884`) | **NOT reachable — corrected 2026-08-19.** `UtilRestController` is annotated **`@Service`**, not `@RestController`, has no class-level `@RequestMapping`, and is injected nowhere in `src/main`. `RequestMappingHandlerMapping.isHandler()` requires `@Controller` or a type-level `@RequestMapping`, so **none of its 9 endpoints route**. Already documented by archived plan `SBDEV-2222-rest-inbound-no-idempotency-contract.md:81-84` rows 16a–16d | no — dead like `initDB`. Fix B still lands, on contract grounds (§5 Fix B) |
| `POST /rest/util/initDB` → 138 × `addFunctionToRole` (`UtilRestController:273-416`) + 2 × `addFunctionToUser` (`:257,258`) | **Dead** — confirmed by the requester 2026-08-19, *and* unroutable for the `@Service` reason above | **no** — do not edit, do not test, do not count in acceptance |
| `AccessService.addFunctionToGroup` | No production caller found outside `initDB` | **yes** — Fix C, to keep it correct rather than to repair it |
| `PUT/PATCH/DELETE /v3/userRole/{id}/functions` (Spring Data REST association endpoint, from `UserRoleRepository`'s `@RepositoryRestResource` + `UserRole.functions`) | **Live** — and **correct by construction**: Hibernate builds the row from the `@JoinTable` mapping, so it cannot transpose the columns | no — nothing to fix, but it is the reason row 14 matters |

---

## 5. Design / Proposed Fix

Guiding constraint: **the record's declared component order is the contract; every caller conforms to it.** The alternative — reordering the record's components to match the callers — is rejected in §12.1.

### Fix A — `UserRoleController.saveRoleFunctions`: pass the components in declared order

`controller/UserRoleController.java:98`

```java
// Before
UserRoleUserFunctionId compositId =
    new UserRoleUserFunctionId(Long.valueOf(functionId), Long.valueOf(roleId));

// After
UserRoleUserFunctionId compositId =
    new UserRoleUserFunctionId(Long.valueOf(roleId), Long.valueOf(functionId));
```

### Fix B — `UserFunctionService.addRoleToFunction`: same, and align the write with the read

`service/UserFunctionService.java:51`

```java
// Before
UserRoleUserFunctionId compositId = new UserRoleUserFunctionId(functionId, roleId);

// After
UserRoleUserFunctionId compositId = new UserRoleUserFunctionId(roleId, functionId);
```

After this, the guard at `:49` (`findByRolelistIdAndFunctionlistId(roleId, functionId)`) and the insert describe the same row, so the idempotency guard starts working — a repeat grant becomes a no-op instead of a PK-violating insert.

### Fix C — `AccessService.addFunctionToGroup`: un-reverse the call site (mandatory with Fix B)

`service/AccessService.java:146`

```java
// Before — reversed on purpose or by accident; cancels the bug in addRoleToFunction
userFunctionService.addRoleToFunction(function.getId(), connector_role.getId());

// After — matches addRoleToFunction(Long roleId, Long functionId)
userFunctionService.addRoleToFunction(connector_role.getId(), function.getId());
```

Compare with the already-correct sibling two methods up (`AccessService:102`, `addFunctionToUser`), which passes `(connector_role.getId(), function.getId())`. Fix C makes `:146` identical in shape to `:102`.

### Fix D — make the replace atomic, in the service layer

Move the delete-then-insert body out of the controller into `UserRoleService`, under the **tenant** transaction manager. `UserRoleService` is already constructor-injected into `UserRoleController` (`:45`), so no new bean wiring is needed **at the controller**.

`UserRoleService` itself does need one new dependency: its constructor (`service/UserRoleService.java:28-34`) currently takes `UserGroupUserRoleRepository, UserRoleRepository, BasicService`, and `replaceRoleFunctions` needs `UserRoleUserFunctionRepository` added. Expect the constructor signature to change — and note that until it does, `@InjectMocks` in `UserRoleServiceUnitTest` will silently not inject the new mock, which is one reason the gate tests fail.

**REVISED 2026-08-19 after review — the first draft of this fix was delete-all-then-reinsert, which is unsafe. See "Why a set difference, not delete-all" below; that analysis is the reason this section changed.**

`service/UserRoleService.java` — new method:

```java
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public void replaceRoleFunctions(Long roleId, List<Long> functionIds) {
    Set<Long> desired = new LinkedHashSet<>(functionIds);

    Map<Long, UserRoleUserFunction> existing = new HashMap<>();
    for (UserRoleUserFunction row : userRoleUserFunctionRepository.findByRolelistId(roleId)) {
        existing.put(row.getFunctionlistId(), row);
    }

    // remove only what is no longer wanted
    existing.forEach((functionId, row) -> {
        if (!desired.contains(functionId)) {
            userRoleUserFunctionRepository.delete(row);
        }
    });

    // add only what is not already there
    desired.forEach(functionId -> {
        if (!existing.containsKey(functionId)) {
            userRoleUserFunctionRepository.save(
                new UserRoleUserFunction(new UserRoleUserFunctionId(roleId, functionId)));
        }
    });
}
```

#### The table's PRIMARY KEY is schema drift — do not rely on it

`db/migration/V2.2.00__base_v2_schema.sql:1512-1515` creates the table with two columns and **no primary key**, and no later `V2.2.x` adds one (`ddl-auto=none`, so Hibernate will not either):

```sql
CREATE TABLE public.mywms_role_mywms_function (
    rolelist_id bigint NOT NULL,
    functionlist_id bigint NOT NULL
);
```

Live tenants *do* have one, but it was created out-of-band — and the names disagree, which is the evidence: `mywms_role_mywms_function_pk` on `wms2-hydra-uat`, `mywms_role_mywms_function_pkey` on `wsl-wineco-uat`. A tenant provisioned fresh from `db/migration/` therefore has **no uniqueness guarantee at all**: duplicate rows commit silently, and the next `findByRolelistIdAndFunctionlistId` — which returns `Optional` — throws `IncorrectResultSizeDataAccessException`.

Two consequences for this plan: any argument of the form "the PK will catch it" is void on a migration-built database, and no migration-built integration test could demonstrate duplicate-key behaviour. The set-difference design does not depend on the constraint existing, which is a further reason to prefer it. Adding the missing constraint is worth a **separate** ticket — this plan deliberately claims no `V2.2.x` version (§7.1-P4), and `V2.2.17` is already contested.

#### Why a set difference, not delete-all — two independent blockers

**1. Hibernate orders inserts before deletes within a single flush.** `ActionQueue` executes `EntityInsertAction` well before `EntityDeleteAction`. A role's function set is normally *edited*, not replaced wholesale, so most keys appear in both the delete set and the insert set. Deleting `(role, fn)` and re-inserting the same `(role, fn)` in one transaction therefore issues the INSERT while the row is still present, violating `PRIMARY KEY (rolelist_id, functionlist_id)` — a `23505` that only appears once Bug 1 is fixed and inserts actually reach the database. Fixing Bug 1 without this would swap a 100%-reproducible FK error for a subtler duplicate-key error on the common path.

This repo has been bitten by exactly this class of defect before: a `REQUIRES_NEW` → `REQUIRED` correction that still threw `23505` because it lacked an explicit `flush()` between the delete and the insert.

**2. The usual mitigation does not compile here.** `UserRoleUserFunctionRepository` extends `PagingAndSortingRepository` + `CrudRepository` — **not** `JpaRepository`:

```java
// repo/jpa/UserRoleUserFunctionRepository.java:15
public interface UserRoleUserFunctionRepository
    extends PagingAndSortingRepository<UserRoleUserFunction, UserRoleUserFunctionId>,
            CrudRepository<UserRoleUserFunction, UserRoleUserFunctionId> {
```

`flush()` is declared on `JpaRepository`, so `userRoleUserFunctionRepository.flush()` **will not compile**. (Contrast `ReplenishorderRepository extends JpaRepository`, which is why `ReplenishGeneratorService:275,328` can call `flush()`.) Working around it would mean either injecting an `EntityManager` purely to call `flush()` — precedent exists at `BillofladingService:651,1400` — or widening the repository's base interface, which is risky: it carries `@RepositoryRestResource`, so changing its inheritance changes the exposed Spring Data REST surface.

The set-difference form needs neither. It never deletes a key it is about to re-insert, so there is no ordering hazard to mitigate, nothing to flush, and no interface change.

**A third benefit worth noting:** because the entity has no `@Version` and never implements `Persistable`, its `@EmbeddedId` is always non-null, so `SimpleJpaRepository.save()` resolves `isNew()` to false and calls `merge()` — which issues a `SELECT` before every write. Touching only the changed rows removes those wasted round-trips on the common "edit one checkbox" path.

**Do not load `UserRole` inside this transaction.** `UserRole.functions` (§0 row 14) is a `@ManyToMany(fetch = EAGER)` `@JoinTable` over *the same table*, and Hibernate treats the two mappings as unrelated. Adding an innocent-looking `userRoleRepository.findById(roleId)` validation inside `replaceRoleFunctions` would eagerly load that collection, and a collection action could then re-insert rows the entity-level delete just removed. If role-existence validation is wanted, do it **before** the transactional method, or via a projection that does not touch `functions`.

`rollbackFor` is retained for consistency with the codebase convention in `CLAUDE.md`, though it is not load-bearing here: the failure modes in this method (`DataIntegrityViolationException`, `EntityNotFoundException`) are all unchecked and would roll back by default.

`controller/UserRoleController.java:85-104` — the endpoint becomes a thin adapter:

```java
@PostMapping(path = "/saveRoleFunctions", consumes = "application/json", produces = "application/json")
public ResponseEntity<Object> saveRoleFunctions(@RequestBody Map<String, Object> reqMap,
                                                @AuthenticationPrincipal Principal principal) {
    Long roleId = ((Integer) reqMap.get("roleId")).longValue();
    List<Long> functionIds = ((List<Integer>) reqMap.get("functions")).stream()
            .map(Integer::longValue).toList();
    LOG.info("save role functions for roleId={} functions={}", roleId, functionIds);
    userRoleService.replaceRoleFunctions(roleId, functionIds);
    LOG.info("role functions saved for roleId={}", roleId);
    return ResponseEntity.ok(Boolean.TRUE);
}
```

Notes on this fix:
- `value = "tenantTransactionManager"` is **not optional**. `landlordTransactionManager` is `@Primary`, so a bare `@Transactional` would route the role/function writes at the landlord DB (project `CLAUDE.md`, Dual Transaction Manager). `UserRoleService` currently has no `@Transactional` at all, so this is the class's first — get it right.
- Deduplication is inherent: `desired` is a `Set`, so a request listing the same function twice inserts once. This supersedes the first draft's `.distinct()`, whose stated justification ("guards the PK") was in any case unsound — see the PK-drift note below.
- **Do not put `@Transactional` on `AdminController`.** It is the base class for 43 controllers; annotating it would open a tenant transaction around every endpoint in the application. `UserRoleController extends AdminController` — the annotation belongs on the service method only.
- Fix A's edit is subsumed by Fix D when the body moves. Keep Fix A as a separate reviewable step so the orientation change is legible in isolation and its test can be written first; the final diff has one construction site in `UserRoleService`.

### Fix F — `AccessService`: two reads query the wrong column (latent)

`service/AccessService.java:256` (`findConnectionGroupToFunction`) and `:284` (`findConnectionUserToFunction`) both do:

```java
// Before — a ROLE id passed to a query filtered on functionlist_id
List<UserRoleUserFunction> functionList = userRoleUserFunctionRepository.findByFunctionlistId(role.getId());

// After
List<UserRoleUserFunction> functionList = userRoleUserFunctionRepository.findByRolelistId(role.getId());
```

The subsequent `f.getFunctionlistId()` lookup at `:258` / `:286` is then correct.

These are the READ-side expression of the same orientation confusion. Against correctly-oriented rows the query can essentially never match, so `findConnectionUserToFunction` / `findConnectionGroupToFunction` always return empty. Consequences, all latent:

- the idempotency guards at `AccessService:93` and `:140` never fire, so every repeat grant mints another connector group/role;
- `removeFunctionFromUser` / `removeFunctionFromGroup` are silent no-ops.

**Latent, not live** — the only callers are in the unroutable `UtilRestController` (§4). Included anyway because §5's guiding constraint is that every caller conforms to the record's contract, and on exit two would not. It is a two-token change.

Requires updating the fixture stubs at `AccessServiceUnitTest.java:183,212,244`, which currently stub the wrong-column query.

### Fix E — correct the two misleading log lines

`controller/UserRoleController.java:87` and `:102` are replaced by Fix D's rewrite above (`"save role functions for roleId=…"` / `"role functions saved for roleId=…"`). No `printerId` lookup, and the success line no longer claims a delete.

**Also fix `:73`** — `LOG.info("delete printer with Id {}", roleId)` in `deletRole` → `LOG.info("delete role with Id {}", roleId)`. This is deliberately in scope even though §0 row 15 defers `deletRole`'s FK-cleanup bug: it is a one-word correction to the same copy-paste string, it touches no logic, and **without it the acceptance check for Fix E cannot pass at all.** A file-wide "no `delete printer with Id` in `UserRoleController`" assertion is unsatisfiable while `:73` keeps the string, and scoping the check to `saveRoleFunctions` instead would leave a known-wrong log line in place with a green suite. Fixing the string is cheaper and more honest than narrowing the check.

Leave `:80`'s `"Role with Id {} is deleted"` alone — in `deletRole` that statement is true.

---

## 6. V1/V2 Applicability

**P3 RESOLVED 2026-08-19 — split verdict: Bug 1 is v2-only, Bug 2 and Bug 3 exist identically in v1.**

**Bug 1 (orientation) — does NOT exist in v1.** It was introduced by the Spring Boot 3.5 `@EmbeddedId` positional-record conversion (`5442a06a`), which is v2-specific. v1 still assigns through named setters at every site, and named setters cannot be transposed:

```java
// v1 controller/RoleController.java:96-97 — the direct counterpart of v2's UserRoleController:98
roleFunction.setFunctionlistId(Long.valueOf(functionId));
roleFunction.setRolelistId(Long.valueOf(roleId));

// v1 service/FunctionService.java:47-48 — counterpart of v2's UserFunctionService:51
funcRole.setFunctionlistId(functionId);
funcRole.setRolelistId(roleId);
```

Note that v1's setter lines are in the same function-first order that misled the v2 conversion — which is precisely why the v2 rewrite produced reversed arguments. v1 is safe *because* it never went positional. Nothing to port.

**Bug 2 (non-atomic replace) — EXISTS in v1, identically.** `v1/wms-api/src/main/java/net/aim_ai/wms/controller/RoleController.java:82-102` is the same shape as the v2 endpoint: `findByRolelistId` → `delete` per row → `save` per row, with **zero** `@Transactional` in the whole controller (grep count: 0). One failed save leaves the role with no functions, exactly as in v2.

**Bug 3 (misleading logs) — EXISTS in v1, identically.** `RoleController.java:84` logs `"delete printer with Id " + reqMap.get("printerId")` on the save path, and `:100` logs `"Role with Id ... is deleted"` on success.

**Action: none.** Per Nam's direction of 2026-08-19 — *"we are going to fix only v2 from now on unless I explicitly tell you to"* — **no v1 ticket is filed.** The finding above is recorded as an observation, not as work. Do not port Fix A/B/C to v1 either; there is nothing there to fix.

---

## 7. Prerequisites & Implementation Plan

### 7.1 Prerequisites

| # | Item | Status | Detail |
|---|------|--------|--------|
| P1 | **Tenant audit for silently-committed swapped rows** | **DONE — no repair needed** | See below. 8 of 9 known v2 tenants audited, 0 corrupt rows |
| P2 | **prd tenant not yet audited** | **OPEN — must run before sign-off** | The one prd v2 tenant (`wh01_hydra_v2`) has no MCP in this session. One read-only query, no write. Command in P1 below |
| P3 | v1 applicability check | **DONE 2026-08-19** | §6 — split verdict: Bug 1 v2-only; Bugs 2+3 exist identically in v1 `RoleController:82-102`, needing a paired v1 ticket |
| P4 | Flyway migration | **N/A** | No schema change. No data repair (P1). **Do not claim a `V2.2.x` version** — `V2.2.17` is contested between SBDEV-2968 and SBDEV-2994 and this plan must not add to that |
| P5 | Feature flag / sysprop | **N/A** | A pure correctness fix; gating it would mean shipping a config in which granting a function still 500s |
| P6 | Deploy order | **N/A** | API-only. No UI change: the web UI already sends the correct `{roleId, functions}` payload (`store/admin/role.js:70`, `roleFunctionEdit.vue:93`) |
| P7 | Coordination with SBDEV-2967 / SBDEV-2968 | **OPEN — decide merge order** | §12.3. This is a likely **prerequisite** for both |
| P8 | Access to a tenant + admin account for the manual test | OPEN | §8 Manual test plan needs one role with ≥1 existing function, to prove the atomicity fix |

**P1 audit — evidence.** A swapped write can only *commit* where a function id also exists as a role id. Run per tenant:

```sql
SELECT (SELECT count(*) FROM mywms_role r JOIN mywms_function f ON r.id = f.id)   AS id_overlap,
       (SELECT count(*) FROM mywms_role_mywms_function
          WHERE rolelist_id = functionlist_id)                                     AS both_equal,
       (SELECT count(*) FROM mywms_role_mywms_function)                            AS join_rows;
```

| Tenant | `id_overlap` | Corrupt rows | Verdict |
|---|---|---|---|
| `wsl-wineco-uat` | 0 | 0 | clean |
| `wms2-wineco-dev` | 0 | 0 | clean |
| `wms2-hydra-uat` | 0 | 0 | clean |
| `nywh-hydra-uat` | 0 | 0 | clean |
| `wms2-hydra-dev2` | 0 | 0 | clean |
| `c1wh-shipitez-uat` | 0 | 0 | clean |
| `nywh-shipitez-uat` | 1 | 0 | clean |
| `wms2-hydra-v2t` | **1** | 0 | clean — investigated below |
| prd `wh01_hydra_v2` | not run | not run | **P2** |

`wms2-hydra-v2t` reported 11 rows whose `rolelist_id` is also a function id, which looked like corruption and is not:

```sql
SELECT r.id, r.name, f.name FROM mywms_role r JOIN mywms_function f ON r.id = f.id;
-- → {id: 579, role: 'inventory-manager', function: 'MOBILE_UI_VIEW_CANCELLATION'}
SELECT count(*) FROM mywms_role_mywms_function WHERE rolelist_id = functionlist_id;  -- → 0
```

Id `579` is simultaneously a role and a function on that tenant. The 11 rows are `inventory-manager`'s legitimate function grants. With exactly one colliding id, the only shape a committed swapped row could take is `rolelist_id = functionlist_id`, and there are none.

**This is the finding that makes the priority `high` rather than `normal`.** Two tenants already have a role id and a function id that collide. The dual-island id space (`seqentities`) offers no structural guarantee of separation, and on `wsl-wineco-uat` the two ranges fully overlap numerically (roles `51800–821840800`, functions `51700–679602`). The next collision turns this bug from an FK violation into a **silent authorization misgrant** — the wrong function attached to the wrong role, with no error anywhere. Nothing in the code or schema prevents that; only the current id values do.

### 7.2 Implementation checklist

1. Confirm the TDD-gate tests exist and fail for the right reason (§8 Test plan), on the branch, before touching production code.
2. **Fix B + Fix C together, in one commit** — `UserFunctionService:51` and `AccessService:146`. Neither in isolation. Run `AccessServiceUnitTest` + `UserFunctionServiceUnitTest`.
3. **Fix A + Fix D + Fix E** — extract `UserRoleService.replaceRoleFunctions`, rewrite the endpoint, correct the logs. Run `UserRoleControllerUnitTest` + `UserRoleServiceUnitTest`.
4. Strengthen the pre-existing blind-spot tests to `ArgumentCaptor` assertions (§8).
4.5 **Retire the reflection scaffolding.** The `ReplaceRoleFunctions` tests use reflection only so they compile before the method exists; reflection never fails to compile, so leaving it in place means a later rename degrades into a runtime `NoSuchMethodException` instead of a build break, and `method.invoke` wraps real failures in `InvocationTargetException`, ruining assertion output. Once `replaceRoleFunctions` compiles:
   - **DELETE** `methodExists` — dead weight; every sibling test proves existence by calling it.
   - **REWRITE** `writesCorrectOrientation`, `deduplicatesFunctionIds`, `doesNotChurnUnchangedAssignments`, `removalsBeforeAdditions` as direct calls.
   - **KEEP** `isTenantTransactional` as reflection — it legitimately needs `getAnnotation`.
   - **ADD** `UserRoleServiceTransactionBoundaryTest` per §8 (mock `tenantTransactionManager`, assert rollback).
5. `mvn clean compile`, then `mvn test`. Expect the 2 known pre-existing `develop` failures and nothing new; **revert the archunit_store mutation** `mvn test` leaves in the working tree.
6. Run `bash sbdocs/9-System/scripts/verify-SBDEV-3005-role-function-composite-key-swap.sh` → `0 fail`.
7. Manual test (§8) on a tenant, including the atomicity case.
8. Close P2 and P3.

---

## 8. Test Plan

### Constraint that shapes this whole section

`BaseControllerUnitTest` builds MockMvc with `MockMvcBuilders.standaloneSetup(controller)` — **no Spring context, therefore no transaction proxy.** A `@Transactional` annotation is completely unexercised by controller unit tests: they pass identically whether the annotation is present, absent, or points at the wrong transaction manager. Combined with the v2 Testcontainers IT harness being broken (SBDEV-2217), **Fix D's atomicity cannot be proven by an automated test in this repo today.** It is covered by:
- a unit test on `UserRoleService.replaceRoleFunctions` asserting delete-happens-before-save ordering (`InOrder`) — proves the sequence, not the rollback;
- a static assertion that the annotation is present *and* names `tenantTransactionManager` — proves the wiring, not the behaviour;
- the manual test below — proves the rollback.

**CORRECTED 2026-08-19 — the "unprovable" claim above was too strong.** Review identified a lane that proves the boundary *behaviourally* with no database at all, defeating both obstacles: a Spring slice with `@SpringJUnitConfig` + `@EnableTransactionManagement`, the real `UserRoleService` bean, mocked repositories, and a **mock `PlatformTransactionManager` whose bean name is `tenantTransactionManager`**. Make a `save` throw, then assert `rollback(...)` was called and `commit(...)` was not. No Testcontainers, no H2, no OSIV — so neither SBDEV-2217 nor `standaloneSetup` applies. Roughly 30 lines.

This is strictly better than the reflection test it supplements, because it catches the `@Primary`-landlord mistake **behaviourally**: a bare `@Transactional` would bind to the landlord manager and the mock tenant manager would never see the transaction, whereas a reflection test only compares an annotation string.

**Written, and it works.** `UserRoleServiceTransactionBoundaryTest` is in the gate worktree; its three tests fail on `NoSuchMethodException` only — the Spring context itself starts clean, which is the part that could have gone wrong. `UserRoleService` is registered via `@Import(UserRoleService.class)` rather than an explicit `@Bean`, so Spring autowires whatever constructor exists and the test survives Fix D adding `UserRoleUserFunctionRepository` to it. A `@Primary` mock `landlordTransactionManager` sits alongside the tenant one specifically so a bare `@Transactional` would be caught: the landlord mock would serve the transaction and the assertions would fail.

Only the *final commit/rollback against real Postgres* remains manual (M4). Do not let a green suite be read as "atomicity verified end-to-end" — but it is no longer true that nothing automated can prove it.

### Why the current tests are green on a permanently broken path

`unit/controller/UserRoleControllerUnitTest.java:147-190` exercises `saveRoleFunctions` twice and asserts:

```java
verify(userRoleUserFunctionRepository, times(3)).save(any(UserRoleUserFunction.class));
```

`any(...)` never inspects the composite key, so the orientation is invisible. The same blind spot exists at `AccessServiceUnitTest.java:166,233,284` (`verify(userFunctionService).addRoleToFunction(200L, 30L)` — asserts the delegation, never the persisted row) and `UserFunctionServiceUnitTest.java:100-130`. Every one of these passes today against code that cannot write a single valid row.

### New / updated tests

Reconciled 2026-08-19 with what the TDD gate actually wrote — the earlier table listed intended names that drifted (and carried a typo, `addRoleToFunctionGuardMatchesWhatItWould Insert`).

| Test | Class | Guards | State on unfixed code |
|---|---|---|---|
| `savesRoleFunctionsWithRoleIdInRolelistColumn` | `UserRoleControllerUnitTest` | Fix A | **FAILS** — `expected: 12L` ×3 |
| `shouldPersistRoleIdInRolelistColumn` | `UserFunctionServiceUnitTest` | Fix B | **FAILS** — `expected: 20L` |
| `repeatGrantShortCircuits` | `UserFunctionServiceUnitTest` | Fix B (idempotency) | passes today — regression guard |
| `whenFunctionNotAlreadyAdded_createsConnectorRole` (pre-existing, **flipped**) | `AccessServiceUnitTest` | **Fix C** | **FAILS** — `Argument(s) are different!` |
| `methodExists` | `UserRoleServiceUnitTest` | Fix D | **FAILS** — `NoSuchMethodException`. **Delete after implementation** (§7.2 step 4.5) |
| `isTenantTransactional` | `UserRoleServiceUnitTest` | Fix D / AC-6 | **ERRORS** — `NoSuchMethodException`. Keep as reflection; it needs `getAnnotation` |
| `writesCorrectOrientation` | `UserRoleServiceUnitTest` | Fix D / AC-1 | **ERRORS** — `NoSuchMethodException` |
| `doesNotChurnUnchangedAssignments` | `UserRoleServiceUnitTest` | **AC-13 minimality** | **ERRORS** — `NoSuchMethodException` |
| `removalsBeforeAdditions` | `UserRoleServiceUnitTest` | Fix D ordering | **ERRORS** — `NoSuchMethodException` |
| `deduplicatesFunctionIds` | `UserRoleServiceUnitTest` | AC-14 | **ERRORS** — `NoSuchMethodException` |
| `failingSaveRollsBackOnTenantManager` | **`UserRoleServiceTransactionBoundaryTest`** (new) | **AC-5 rollback** | **ERRORS** — `NoSuchMethodException` |
| `successfulReplaceCommitsOnTenantManager` | `UserRoleServiceTransactionBoundaryTest` | AC-5 / AC-6 | **ERRORS** — `NoSuchMethodException` |
| `methodIsTransactionallyProxied` | `UserRoleServiceTransactionBoundaryTest` | AC-6 | **ERRORS** — `NoSuchMethodException` |
| `removeFunctionFromUserLooksUpByRolelistId` | `AccessServiceUnitTest.ConnectorLookupColumn` (new) | **AC-16 / Fix F** | **FAILS** — the chain is never walked |
| `addFunctionToUserGuardActuallyFires` | `AccessServiceUnitTest.ConnectorLookupColumn` (new) | AC-16 / Fix F | **FAILS** — the guard misses, so a second connector chain is minted |
| `whenFunctionAlreadyAdded_doesNothing` (pre-existing, **stub flipped**) | `AccessServiceUnitTest` | AC-16 | **FAILS** |
| `whenFunctionRemoved_removesConnectorChain` (pre-existing, **stub flipped**) | `AccessServiceUnitTest` | AC-16 | **FAILS** |

**Both test debts are now closed (2026-08-19).** The transaction-boundary slice test (AC-5) and Fix F's coverage (AC-16) were written after the review pass, so every fix A–F now has a failing test ahead of its code.

Two notes on how they were written:

- **The pre-existing `AccessServiceUnitTest` tests were stubbing the bug.** `whenFunctionAlreadyAdded_doesNothing` and `whenFunctionRemoved_removesConnectorChain` stubbed `findByFunctionlistId(20L)` — passing the connector *role* id to the query filtered on `functionlist_id`. That is why the wrong-column read survived: the tests described the defect and agreed with it. Both stubs are flipped to `findByRolelistId(20L)`, and verify row `T5` now forbids any test naming the wrong-column query.
- **Failures were made legible.** With the stubs flipped, the guard misses on broken code and execution falls through to `groupService.createEntity()`, an unstubbed mock returning `null` → NPE. An NPE reads like a badly-written test, not a product defect. Connector fixtures are now stubbed `lenient()` so the failure is a clean "wanted never, was invoked"; `lenient()` because on fixed code the guard fires and those stubs go unused, which would otherwise trip `MockitoExtension`'s `STRICT_STUBS`. `AccessServiceUnitTest` now reports `Failures: 5, Errors: 0`.

Assertions must be on `getRolelistId()` / `getFunctionlistId()`, never on `getId().equals(...)` with a hand-built expected record — an expected record built with the same reversed argument order would match a wrong row and pass. (`writtenRowMustMatchTheGuardedRow` did exactly that and was removed for it.)

### Regression

- `AccessServiceUnitTest`, `UserGroupControllerUnitTest`, `UserControllerUnitTest`, `UserGroupServiceUnitTest`, `EntityUnitTest`, `EntityEqualsHashCodeContractTest` — all touch these records; none should change behaviour.
- §0 rows 4–7 must remain untouched. Any diff to `UserGroupUserId` / `UserGroupUserRoleId` call sites means the fix over-reached.

### Manual test plan

| # | Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| M1 | The reported bug | any v2 tenant | Admin → User Management → Roles → `test role` → add `WEB_UI_LOG_IN` → Save | 200. `SELECT * FROM mywms_role_mywms_function WHERE rolelist_id = <test role id>` shows one row with `functionlist_id = 51700` | |
| M2 | Multi-function save | same | Select 5 functions → Save | 5 rows, all with the role id in `rolelist_id` | |
| M3 | Replace, not append | same | Save 5, then Save a different 3 | exactly 3 rows | |
| M4 | **Atomicity (the Fix D case) — RESTATED 2026-08-19** | same | Role has functions {A,B,C}. POST `saveRoleFunctions` with **{A, B, BOGUS}** — the posted set must **drop at least one existing function (C)** *and* contain one id that will fail | 500 **and** all three of A, B, C still present. The dropped-then-restored C is the only thing that proves rollback | |
| M5 | Idempotent re-grant | same | Save the same set twice | second call 200, row count unchanged, no duplicate-key error | |
| ~~M6~~ | ~~`/initAdmin`~~ | — | **WITHDRAWN 2026-08-19** — `UtilRestController` is `@Service`, not `@RestController`, so the endpoint does not route and this test would 404 for a reason unrelated to the fix. It cannot be an acceptance step (§4) | — | n/a |
| M7 | Log line | any | Trigger M1 and read the log | No `delete printer with Id null`; a `save role functions for roleId=…` line instead | |

| M8 | **No-churn on an overlapping save (the Fix D revision)** | any v2 tenant | On a role with functions {A,B,C}, save {B,C,D}. Then in the DB: `SELECT * FROM mywms_role_mywms_function WHERE rolelist_id = <role>` | exactly {B,C,D}. Under the withdrawn delete-all design this request would have deleted and re-inserted B and C in one transaction — the duplicate-key path (§5) | |

**Why M4 had to be restated.** Under the withdrawn delete-all design, *any* failing save exercised rollback, because every existing row was deleted first. Under the set-difference design the delete set is computed, so posting "all existing functions plus one bogus id" produces an **empty** delete set — the insert fails and there is nothing to roll back. The test would pass while proving nothing. The posted set must drop an existing function for rollback to have a subject. This is a direct consequence of the Fix D revision and was caught in review, not in authoring.

M4 (restated) and the §8 transaction-proxy slice test below are the evidence for AC-5; M8 is the evidence that the set-difference form behaves. All must be run.

### Deliberately-skipped coverage

- **Testcontainers IT for transactional rollback** — the v2 IT harness cannot boot (SBDEV-2217). Covered by M4 only. Recorded as a known gap, not a passing check.
- **`/rest/util/initDB`** — dead code per the requester; its 138 call sites are neither edited nor tested.
- **v1** — §6, pending the P3 grep.

---

## 9. Horizontal Scalability Validation

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | **No** | No new cache, static, or `ThreadLocal` |
| 2 | Connection pool math | **No** | Fix D holds **one** connection for the duration of one small delete+insert batch instead of N sequential connections — strictly fewer acquisitions per request. Bounded by the function count of one role (≤ ~80) |
| 3 | Scheduled jobs | **N/A** | No `@Scheduled` touched |
| 4 | Long transactions | **No** | The new transaction spans only repository calls on one join table — no external I/O, no HTTP |
| 5 | Request affinity | **N/A** | Stateless request/response |
| 6 | Retry / idempotency | **Yes** | Fix B makes `addRoleToFunction`'s guard functional, so a replayed grant is a no-op instead of a duplicate-key error; Fix D's `.distinct()` removes intra-request duplicates. A replayed `saveRoleFunctions` is idempotent by construction (full replace) |
| 7 | Tenant context | **No** | Synchronous request thread; no async boundary crossed |
| 8 | Distributed lock correctness | **No** | No pessimistic lock added. Two admins editing the same role concurrently both do a full replace; last-write-wins, which matches the endpoint's existing semantics. `UserRoleUserFunction` has no `@Version` and is not being given one |
| 9 | Cache invalidation | **Needs confirmation** | Whether `mywms_role_mywms_function` reads sit behind a Caffeine cache determines whether a grant is visible immediately on all replicas. Check `CacheConfig` + `@Cacheable` on the access-check path before sign-off — if `doesUserHaveAccess` is cached, add the eviction |
| 10 | External notifications | **N/A** | No OMS / printer / message send |

### Evidence

| # | What was verified | Reference |
|---|---|---|
| 2 | `SimpleJpaRepository.delete()` currently runs one `REQUIRED` transaction per row; one wrapping transaction replaces N with 1 | `UserRoleController.java:93-95`; project `CLAUDE.md` Dual Transaction Manager |
| 6 | Guard is correctly oriented already; only the write was wrong | `UserFunctionService.java:49` vs `:51` |
| 8 | No `@Version` on the entity | `model/UserRoleUserFunction.java:22-58` |
| 9 | **To be filled by the implementer.** `grep -rn "@Cacheable\|@CacheEvict" src/main/java/net/aim_ai/wms/service/AccessService.java src/main/java/net/aim_ai/wms/config/CacheConfig.java` | pending |

---

## 10. v2-only constraint checklist

| # | Constraint | Verdict | Where addressed |
|---|---|---|---|
| 1 | OSIV disabled | **Yes** | It is *why* Bug 2 loses data: nothing holds the deletes and inserts together. Fix D supplies the boundary explicitly (§5 Fix D) |
| 2 | Transaction manager | **Yes** | Fix D specifies `value = "tenantTransactionManager"`; a bare `@Transactional` would hit the `@Primary` landlord TM (§5 Fix D notes) |
| 3 | `readOnly = true` on reads | **N/A** | No read-only method added. `getUserRoleDetails` is out of scope |
| 4 | Caffeine cache invalidation | **Needs confirmation** | §9 row 9 |
| 5 | Jakarta namespace | **Yes** | `jakarta.persistence` throughout; no v1 code ported (§6) |
| 6 | H2-compatible test SQL | **N/A** | All new tests are Mockito unit tests; no SQL |
| 7 | `BaseControllerTest` for controller changes | **Yes** | `UserRoleControllerUnitTest` already extends `BaseControllerUnitTest`; note its `standaloneSetup` limitation (§8) |
| 8 | Micrometer metrics | **No** | Low-frequency admin path; no metric warranted |

---

## 11. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Fix B lands without Fix C** | `addFunctionToGroup` silently starts writing reversed rows — the bug moves rather than dies | Same commit, enforced by the verify script's Fix C row and `addFunctionToGroupPersistsRoleIdInRolelistColumn` |
| Someone "fixes" this by reordering the record's components instead | The three correct sibling records keep their order while this one flips, so the codebase loses its single convention; every `@Column` mapping and both FK names would need re-checking | Rejected in §12.1 with rationale; verify script asserts the record's declared order is unchanged |
| A tenant develops a role-id / function-id collision before this ships | Swapped write commits silently → wrong function granted to wrong role, no error | §7.1-P1 audit; ship promptly. Two tenants already have one colliding id |
| Fix D's atomicity cannot be automatically verified | A future refactor could drop the annotation with the suite still green | `replaceRoleFunctionsIsTenantTransactional` reflection test + M4 manual |
| `@Transactional` accidentally added to `AdminController` | Opens a tenant transaction around every endpoint of 43 controllers | Called out in §5 Fix D; verify script asserts `AdminController` has no `@Transactional` |
| Overlap with SBDEV-2967 / SBDEV-2968 | Merge conflicts, or two plans changing gating simultaneously | **Partly mitigated, partly accepted.** §12.2's deferral keeps the diff off `UserController` entirely. It does **not** cover `AccessService`: Fix C edits `:146` and Fix F edits `:256`/`:284`. That overlap is **accepted** — the edits are three lines in two methods and rebase trivially — not mitigated. Stated plainly rather than implied away |
| **Two independent mappings of one table** — the `UserRoleUserFunction` entity and `UserRole.functions` (`@ManyToMany`, EAGER) | Hibernate does not reconcile them. Code that writes through the entity while the collection is loaded in the same persistence context can produce conflicting or duplicate collection actions | Fix D touches only the repository and never loads `UserRole` (§5 Fix D). Reviewers must reject any later addition of a `userRoleRepository.findById` inside that transaction |
| The plan originally justified Fix B by a "live second path" (`/initAdmin`) that is **not routed** | Had it gone unchallenged, an acceptance step (M6) would have 404'd and been misread as a fix failure | Corrected in §4; M6 withdrawn; Fix B re-justified on contract grounds. Found only because a second lane checked reachability rather than trusting the call graph |

---

## 12. Notes

### 12.1 Rejected alternative — reorder the record instead of the callers

Swapping `UserRoleUserFunctionId`'s two components would fix both call sites with a one-line change. Rejected:

- The record's component order matches its `@Column` names, the table's PK column order (`PRIMARY KEY (rolelist_id, functionlist_id)`), and the three sibling records' role-before-target convention. The callers are the outliers, not the record.
- `UserRoleUserFunction.getRolelistId()` / `getFunctionlistId()` read `id.rolelistId()` / `id.functionlistId()`; flipping the record silently inverts both accessors and every read path built on them.
- The correct-by-accident `AccessService:146` would become correct-by-accident in the opposite direction, leaving two conventions in one file.

Fixing the callers is three lines and leaves one convention standing.

### 12.2 Deferred — the same non-atomic pattern on two sibling endpoints

`UserGroupController.saveGroupRoles` (`:99-117`) and `UserController.saveUserGroups` (`:310-334`) are the same delete-then-insert-with-no-transaction shape as Bug 2. Their composite keys are correctly oriented, so they do not 500 — but a partial failure leaves a user with no groups or a group with no roles, which is the same authorization-erasing outcome.

A third, worse instance sits in the same controller: **`UserRoleController.deletRole:71-82`** clears `mywms_role_mywms_function` and then calls `userRoleRepository.deleteById(roleId)` — but never clears `mywms_group_mywms_role` or `mywms_user_mywms_role`, both of which FK to `mywms_role(id)` (`fk2k1nyn576adktb9r318x6x90` and `fkiyrof2dr48h37rnp0owmwguuk`, verified on `wms2-hydra-uat`). **Deleting any role that is bound to a group or a user therefore 500s** — a live, reproducible bug, not merely a non-atomicity concern. It belongs with the same follow-up.

Deferred from SBDEV-3005, with the reasons stated honestly per endpoint — review pointed out that the original single rationale covered only one of them:

- **`UserController.saveUserGroups`** — a real, specific churn reason: SBDEV-2870 has just changed that file (PR #166, `989611e`) and SBDEV-2967 is about to change it again.
- **`UserGroupController.saveGroupRoles`** — **the churn argument does not apply**; no in-flight plan touches that file, and the fix is the identical extraction with `groupId`/`roleIds` substituted. It is deferred purely for **scope discipline: one ticket, one endpoint.** That is a weaker justification and is recorded as such rather than borrowed from its neighbour.
- **`UserRoleController.deletRole`** — in the very file being rewritten, and deferred anyway. Also weak; the honest reason is that its FK-cleanup bug is a *different* defect needing its own acceptance criteria, not the atomicity pattern.

The boundary here was drawn by **file**, not by defect. That is a defensible call for a focused ticket, but it should not be dressed up as anything more. **File it as a follow-up ticket** rather than losing it — it is a real data-loss path, and `saveUserGroups` is the endpoint noted elsewhere as being able to rewrite the very table the access check reads.

### 12.3 Coordination — SBDEV-3005 is probably a prerequisite for SBDEV-2967 / SBDEV-2968

Both in-flight plans add **enforcement** of function gates:
- SBDEV-2967 — web UI has no authorization layer, menu hardcoded to super-admin (draft)
- SBDEV-2968 — mobile tiles gated client-side only (GATE-READY, blocked on a Keycloak account)

Enforcement assumes functions can be **assigned**. Today the only working assignment path is the migration base dump; the admin UI's role→function editor 500s, and `/initAdmin` cannot grant the admin user `WEB_UI_LOG_IN`. Turning on enforcement before this fix risks locking administrators out of the very screens needed to grant access, with no working UI to recover.

**Recommendation: merge SBDEV-3005 before either enforcement plan.** It is a 3-line orientation fix plus one extracted method — far smaller than either, and it does not touch their files (§12.2 keeps the diff clear of `UserController`). Raise this with the SBDEV-2968 owner before that plan leaves its gate.

### 12.4 Review history — two independent lanes, 2026-08-19

The first draft was authored in the same context as the diagnosis and was **not** reviewed. Two independent lanes were then run: an **architect** re-deriving the fix from the code before reading the plan, and a **critic** attacking the plan and the acceptance machinery. Both changed the outcome materially. Every claim either lane made was re-verified first-hand before being folded in; two were adopted only after checking the code directly.

What review changed:

| Finding | Lane | Impact |
|---|---|---|
| **Fix D would 500 on the common case.** Hibernate emits inserts before deletes, so delete-all-then-reinsert collides on a re-added key. `repo.flush()` does not even compile (`CrudRepository`, not `JpaRepository`) | architect (independently reached by the author in parallel) | **Fix D rewritten** as a set difference |
| `/rest/util/initAdmin` is **not routed** — `UtilRestController` is `@Service`, not `@RestController` | architect | §4 corrected, **M6 withdrawn**, Fix B re-justified on contract grounds |
| `AccessService:256`/`:284` read the wrong column | architect | **Fix F** added (§0 row 13) |
| The table's PK is **schema drift** — no migration creates it | architect | §5 note; the `.distinct()`-guards-the-PK argument withdrawn |
| `UserRole.functions` is a **second mapping** of the same table | architect | §0 row 14, §11 risk, `D9` verify row |
| Three verify rows were **permanently red** — `D5` (obsoleted by the Fix D rewrite), `D6` and `E1` (file-wide negatives forbidding strings that legitimately live in `deletRole`) — making the stated `0 fail` target unreachable | critic | All three corrected; Fix E widened to `:73`; §13.3 target recomputed |
| **M4 became vacuous** under set difference: posting "all existing + one bogus" yields an empty delete set, so nothing rolls back | critic | M4 restated to drop an existing function |
| **AC-5 is automatically provable** after all, via a Spring slice with a mock `tenantTransactionManager` | critic | §8's "unprovable" claim corrected; `UserRoleServiceTransactionBoundaryTest` added |
| `A1`/`B1` are satisfiable by a **comment** | critic | `A4` added — method-scoped positive on the real construction site |
| `deletesBeforeSaves` verified nothing; `writtenRowMustMatchTheGuardedRow` used an anti-pattern §8 itself forbids | critic | Both replaced |
| Set-difference **minimality** — the whole point of the revision — had no AC, no verify row, no test | critic | **AC-13** + `doesNotChurnUnchangedAssignments` + `D5`/`D7`/`D8` |
| "Adds no new wiring" was false; §12.2's deferral rationale covered only one of two endpoints; §11 overclaimed mitigation of the SBDEV-2967 overlap | critic | All three corrected |
| §12.2 omitted `deletRole`, which has a live FK bug | architect | §0 row 15, §12.2 |
| §3 regression chain, §6 v1 split verdict, §7.1 tenant audit, §12.1 record-vs-callers decision, and the 9 gate failures | both | **Confirmed** under direct checking |

Both lanes independently confirmed there is no caching on the authz path (§9 row 9) and no data repair needed. Neither could close **P2** (prd tenant) — that remains the one open prerequisite.

### 12.5 Version history

| Date | Change |
|------|--------|
| 2026-08-19 | Created. Diagnosis, §0 enumeration, regression chain isolated to `5442a06a`, 8-tenant corruption audit, `/initDB` scoped out per requester |

---

## 13. Acceptance & Implementation

### 13.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-3005-role-function-composite-key-swap.sh`

Run before the first code change to capture the FAIL baseline, and again at the end. Sign-off requires the script's own final line pasted into the completion report:

```
Result: N pass, 0 fail, M skip
```

**Measured baseline on unfixed `develop` (2026-08-19):**

```
Result: 7 pass, 19 fail, 6 skip        # PROJECT_ROOT=v2/wms2-api SKIP_MVN=1
```

The 7 greens are exactly the invariants that must *not* change: `R1` (record component order), `B3` (the guard's orientation, already correct), `D3` (`AdminController` has no `@Transactional`), `S1`–`S4` (the four already-correct sibling sites). Every row asserting new work is red. If any of those 7 ever goes red, the fix has over-reached.

The script was negative-tested rather than trusted, and that caught three rows that were **green on broken code** and have been rewritten:

| Row | False-green cause | Now |
|---|---|---|
| `C1` | File-scoped grep for the correct call shape matched `addFunctionToUser` at `AccessService:102`, which was already correct — proving nothing about `:146` | Method-scoped tempered-gap match inside `addFunctionToGroup` |
| `E2` | Regex used `\n` under `grep -E`, and the same `"is deleted"` string is legitimate at `:80` in `deletRole` | Asserts no `is deleted ", reqMap.get` — an argument shape unique to the save path |
| `T4` | "`AccessServiceUnitTest` mentions `addFunctionToGroup`" is already true; the existing test asserts delegation, never the row | Requires a `getRolelistId()` column-level assertion |

`D2` was additionally found **permanently red even on correct code**: its tempered gap forbade `public`, which the annotated method's own declaration necessarily contains. A permanently-red row is indistinguishable from unimplemented work. The corrected gap forbids `;` and `@` instead, and was validated against four variants — correct (green), annotation on a different method (red), no annotation (red), and bare `@Transactional` i.e. the landlord-TM mistake (red).

### 13.2 Acceptance criteria

**AC-13 exists because minimality is the whole point of the Fix D revision and nothing else pins it.** Without a criterion, a future "simplification" back to `deleteAll(findByRolelistId(roleId))` + re-insert would leave every other row and test green while restoring the insert-before-delete duplicate-key path. That is precisely the regression this plan was rewritten to prevent.

| # | Criterion | Verified by |
|---|---|---|
| AC-1 | `POST /v3/userRole/saveRoleFunctions` persists `rolelist_id` = role id, `functionlist_id` = function id | **`writesCorrectOrientation`** (the test that actually proves it) + verify rows A4/A2/A3, which are grep-shaped only; M1, M2 |
| AC-2 | `UserFunctionService.addRoleToFunction` persists the same orientation | verify rows B1 **+ B2** (B1 alone is comment-satisfiable); `shouldPersistRoleIdInRolelistColumn` |
| AC-3 | `AccessService.addFunctionToGroup` still writes correct rows after AC-2 | verify row C1; unit test |
| AC-4 | `AccessService.addFunctionToUser` / `addFunctionToRole` write correct rows | verify rows B1+B2 (shared fix); `AccessServiceUnitTest`. **M6 withdrawn** — those endpoints do not route (§4) |
| AC-5 | A failing insert rolls back the preceding deletes; the role keeps its previous functions | `UserRoleServiceTransactionBoundaryTest` — `failingSaveRollsBackOnTenantManager` **and `transactionDefinitionIsAWritableRequiredTransaction`** (the second is required: without it `propagation = NOT_SUPPORTED, readOnly = true` was measured 100% green); verify T6; **+ M4 as restated** (the posted set must drop an existing function, else the delete set is empty and the test is vacuous) |
| AC-6 | The replace runs under `tenantTransactionManager`, with `REQUIRED` propagation and **not** read-only | `isTenantTransactional` (now asserts `value`, `propagation` and `readOnly`, via `AnnotatedElementUtils` so the `transactionManager =` alias is not a false red) + `transactionDefinitionIsAWritableRequiredTransaction`; verify rows D2 + T1 |
| AC-7 | `AdminController` still has no `@Transactional` | verify row D3 |
| AC-8 | Composite-key orientation is asserted by `ArgumentCaptor`, not `any()` | verify rows **T2 + T3** — *not* T1, which was permanently green because the controller test uses `ArgumentCaptor<Long>` for payload widening |
| AC-9 | `UserRoleUserFunctionId`'s declared component order is unchanged | verify row R1 |
| AC-10 | No `delete printer with Id` string remains **anywhere** in `UserRoleController` — including `:73`, without which E1 cannot pass (§5 Fix E) | verify row E1; M7 |
| AC-11 | §0 rows 4–7 unchanged | verify rows S1–S4 |
| AC-12 | P2 (prd audit) closed; P3 closed 2026-08-19 | recorded in §13. **Checklist item, not a machine-checked criterion** — verify row X2 is a SKIP, so the script can report `0 fail` with the prd tenant still unaudited |
| **AC-13** | **Set-difference minimality: an unchanged assignment is neither deleted nor re-inserted.** Role has {A,B}, POST {A,C} → exactly one `delete` (B), exactly one `save` (C), and `delete` is **never** called for A | **`doesNotChurnUnchangedAssignments`** carries this. Verify row D5 was measured *decorative* (green against a real delete-all regression) and has been tightened to require both guarded branches; D7/D8 remain shape-only. M8 |
| **AC-14** | Duplicate function ids in one request insert once | verify row D8; `deduplicatesFunctionIds` |
| **AC-15** | Replace-not-append: saving a smaller set removes the difference, **including down to the empty set** | M3; `doesNotChurnUnchangedAssignments` (proper subsets) **+ `clearsAllAssignmentsWhenDesiredIsEmpty`** — the empty-desired boundary was previously unguarded at every layer |
| **AC-16** | Fix F: no `findByFunctionlistId(role.getId())` remains; both sites use `findByRolelistId` | verify rows F1/F2 |
| **AC-17** | The endpoint delegates to the service method and the controller no longer owns the delete loop | verify rows D4/D6 |

### 13.3 TDD gate — COMPLETE, awaiting approval to implement

Worktree `.claude/worktrees/wms2-api/SBDEV-3005`, branch `bugfix/SBDEV-3005-role-function-composite-key-swap`, based on `origin/develop` @ `e7b3b88`. **Tests are written and left UNCOMMITTED** in the worktree; no production code has been touched.

Nine failing tests across four classes, each failing for the intended reason:

| Class | Test | Guards | Failure |
|---|---|---|---|
| `UserRoleControllerUnitTest` | `savesRoleFunctionsWithRoleIdInRolelistColumn` | Fix A | `expected: 12L` ×3 — the captured rows carry the function id in `rolelist_id` |
| `UserFunctionServiceUnitTest` | `shouldPersistRoleIdInRolelistColumn` | Fix B | `expected: 20L` |
| `UserFunctionServiceUnitTest` | `repeatGrantShortCircuits` | Fix B | **passes today** — a regression guard, not a gate test. It replaced `writtenRowMustMatchTheGuardedRow`, which asserted on a hand-built expected record: the exact anti-pattern §8 forbids, since an expected record built with the same reversed order matches a wrong row |
| `AccessServiceUnitTest` | `whenFunctionNotAlreadyAdded_createsConnectorRole` | **Fix C** | assertion flipped to `addRoleToFunction(200L, 30L)`; the reversed call no longer matches |
| `UserRoleServiceUnitTest` | `ReplaceRoleFunctions` ×6 | Fix D, **AC-13** | `NoSuchMethodException: UserRoleService.replaceRoleFunctions(Long, List)` ×5 plus `methodExists` on its assertion |

`ReplaceRoleFunctions` gained `doesNotChurnUnchangedAssignments` (AC-13 minimality — role {200,300} → {200,400} must delete only 300, save only 400, and never touch 200) and `removalsBeforeAdditions`. These replaced `deletesBeforeSaves`, which review showed **verified nothing**: it asserted `findByRolelistId` before `save`, an order that data flow already forces, and would have passed even if deletes ran after saves — while §8's table claimed it proved "all deletes precede all saves". The claim and the test now agree.

Current gate run: **17 failing tests across five classes**, all for the intended reason —

| Class | Result |
|---|---|
| `UserRoleControllerUnitTest` | 1 failure (Fix A) |
| `UserFunctionServiceUnitTest` | 1 failure (Fix B) |
| `AccessServiceUnitTest` | `Tests run: 39, Failures: 5, Errors: 0` (Fix C ×1, Fix F ×4) |
| `UserRoleServiceUnitTest` | 6 in `ReplaceRoleFunctions` — `methodExists` on its assertion, 5 on `NoSuchMethodException` |
| `UserRoleServiceTransactionBoundaryTest` | 3 on `NoSuchMethodException`; **context starts clean** |

Every pre-existing test in all four classes still passes — the only pre-existing test changed is the `AccessServiceUnitTest` one below, deliberately. `AccessServiceUnitTest` alone reports `Tests run: 37, Failures: 1`, and that one failure is `Argument(s) are different!` on `whenFunctionNotAlreadyAdded_createsConnectorRole:292`.

Verify-script readings, which bracket the work:

| Where | Result | Meaning |
|---|---|---|
| Main checkout (no gate tests, no fix) | `7 pass, 27 fail, 7 skip` | the implementer's FAIL baseline |
| Gate worktree (all gate tests written, no fix) | `13 pass, 21 fail, 7 skip` | all six `T` rows green, proving they are achievable and not permanently red |
| Target after implementation | **`34 pass, 0 fail, 7 skip`** | 34 `run` rows; the 7 skips are the 5 `mvn` rows under `SKIP_MVN=1` plus `X1`/`X2` |

The earlier revision of this section stated a target of `26 pass, 0 fail`. **That was unreachable**, and review caught it: with Fix A–E applied verbatim, three rows stayed red — `D5` (asserted a `.distinct()` call the set-difference design does not make), and `D6`/`E1` (file-wide negatives forbidding strings that legitimately live in `deletRole`, whose own defect §0 row 15 defers). An implementer told to reach `0 fail` would have either given up or "fixed" `deletRole` unreviewed. All three are corrected: `D5` now asserts the diff shape, `D6` is scoped to `saveRoleFunctions` with a tempered gap, and Fix E was widened to clear `:73` so `E1` is satisfiable at all. Row count then grew from 26 to 32 with `A4`, `D7`–`D9`, and `F1`/`F2`.

**The gate's most valuable finding: an existing green test was pinning the bug.** `AccessServiceUnitTest:284` asserted `verify(userFunctionService).addRoleToFunction(30L, 200L)` — function first, role second — which encodes `AccessService:146`'s reversed call as correct behaviour. Anyone fixing `UserFunctionService` in isolation would have seen this test go red and could reasonably have "fixed" it by reverting their change. It is now flipped to the order the method signature declares, so it fails until Fix C lands and passes afterwards.

`ReplaceRoleFunctions` is written by reflection deliberately. A direct call to a method that does not exist would not compile, and a compile failure would take the whole module's tests down — hiding the five orientation tests behind an error that says nothing about the bug. Reflection makes the gate fail on the assertion instead.

Run the gate with:

```bash
export JAVA_HOME=~/.sdkman/candidates/java/21.0.11-ms
export PATH="$HOME/.sdkman/candidates/maven/current/bin:$JAVA_HOME/bin:$PATH"
mvn test -Djacoco.skip=true -Dtest='UserRoleServiceUnitTest,UserFunctionServiceUnitTest,UserRoleControllerUnitTest,AccessServiceUnitTest,UserRoleServiceTransactionBoundaryTest'
```

Do not narrow this to `-Dtest='Class#method'` — that silently no-ops against `@Nested` classes, and every test here lives in one.

### 13.4 Implementation Status — MERGED 2026-08-20

**MERGED 2026-08-20 00:57 UTC** — [wms2-api PR #170](https://github.com/SiteBossInc/wms2-api/pull/170) into `develop`, merge commit `60aef02` (branch commit `f4e78c5`).

Verified on `origin/develop` after the merge: `UserFunctionService:51` constructs `(roleId, functionId)`; `AccessService:102/:127/:146` all pass `(roleId, functionId)`; `:256/:284` use `findByRolelistId`; `UserRoleService:131-132` carries `replaceRoleFunctions` with the tenant transaction manager; and `"delete printer with Id"` no longer appears anywhere in `UserRoleController`.

⚠ **A first deploy attempt on 2026-08-19 reproduced the original error, because the PR had not been merged and the image was built from pre-fix `develop`.** The giveaway was in the log itself: the line `delete printer with Id null` is emitted by code Fix E deletes, so its presence is proof the running image predates the fix. **Use that line as the deployment check** — if it appears, the fix is not in the build, whatever the ticket says.

Worktree `.claude/worktrees/wms2-api/SBDEV-3005`, branch `bugfix/SBDEV-3005-role-function-composite-key-swap`. **Rebased onto `origin/develop` @ `6135203`** — develop advanced by 3 commits (SBDEV-2994) while this was in review; no file overlap with this change, the rebase was clean, and `mvn clean compile` plus the full verify script were re-run on the new base before pushing.

#### Acceptance

```
Result: 39 pass, 0 fail, 2 skip
```

Full run including the five `mvn` rows, re-measured after both code-review lanes. The 2 skips are `X1` (real-Postgres rollback → manual M4) and `X2` (P2, prd audit). The script now restores the ArchUnit freeze store its maven rows mutate, so the tree is clean afterwards.

#### Production changes

| Fix | File:line | Change |
|---|---|---|
| A + D + E | `controller/UserRoleController.java` | `saveRoleFunctions` reduced to parse + delegate; `:73` log corrected to `"delete role with Id {}"`; the `printerId` log and the false `"is deleted"` success line removed; now-unused `UserRoleUserFunctionId` import dropped |
| B | `service/UserFunctionService.java:51` | `new UserRoleUserFunctionId(roleId, functionId)` |
| C | `service/AccessService.java:146` | `addRoleToFunction(connector_role.getId(), function.getId())` — now identical in shape to `:102` |
| D | `service/UserRoleService.java` | new `replaceRoleFunctions(Long, List<Long>)`, `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`, set-difference; `UserRoleUserFunctionRepository` added to the constructor |
| F | `service/AccessService.java:256,284` | `findByRolelistId(role.getId())` |
| M2 (review) | `controller/UserRoleController.java` | payload validation → `ApiInvalidParameterException` (422): `roleId` and every element must be a `Number` (so ids above `Integer.MAX_VALUE`, which Jackson binds as `Long`, no longer break the cast), `functions` must be an array, and the list is capped at 500 |
| M3 (review) | `controller/UserRoleController.java` | `userRoleRepository.existsById(roleId)` + a one-query `findAllById` check on the function ids, both **in the controller** so `replaceRoleFunctions` still never loads `UserRole`. New dependency: `UserFunctionRepository` |
| L4 (review) | `service/UserRoleService.java` | counts tallied inside the two loops instead of three stream passes in the `LOG.debug` arguments |

#### Tests

`mvn clean compile` → success. The five gate classes → **80 tests, 0 failures** (17 controller, 8 user-function, 39 access, 13 user-role, 3 boundary).

One shared test-infrastructure change: `BaseControllerUnitTest` gained an **additive** `setupMockMvc(Object, Object...)` overload that registers `@ControllerAdvice`. Standalone MockMvc registers none by default, so without it an `ApiInvalidParameterException` escapes as a nested servlet exception and the 422 contract cannot be asserted. All 44 existing callers keep the previous no-advice behaviour, because the single-argument overload passes an empty array.

Full suite: **`Tests run: 5164, Failures: 2, Errors: 0, Skipped: 67`**. Both failures are pre-existing on `develop` and unrelated:

- `OptionalSafetyArchTest#noNewOptionalGetCallsInServiceClasses` — 6 violations, all in `PickLineRealignmentService`, `ReplenishGeneratorService`, `UnitloadBusinessService`, `MobileReplenishService`. **None in the three service classes this change touches**, which is what rules it out as a regression.
- `MobilePalletizingServiceTest#testScanParcelBulkPalletAlreadyAssignedToGate`.

`mvn test` mutated `src/test/resources/archunit_store/5fb3fee0-…` as it always does; **reverted**, tree confirmed clean of it.

#### Controller tests were re-pointed at the new seam

Moving the body into the service left all three `SaveRoleFunctions` tests failing — `userRoleService` is a mock there, so the repository assertions no longer described anything. They were rewritten to assert what the controller is now responsible for: delegation and payload widening (`delegatesToServiceAndReturnsTrue`, `widensPayloadToLong`, `delegatesEmptyList`, `controllerDoesNotDeleteDirectly`). The orientation and set-difference assertions live in `UserRoleServiceUnitTest`, where the logic now is. Verify rows `T1`–`T3` were written to accept either file, so they stayed green across the move.

#### Reflection retired (§7.2 step 4.5 — done)

`methodExists` deleted; `writesCorrectOrientation`, `doesNotChurnUnchangedAssignments`, `removalsBeforeAdditions`, `deduplicatesFunctionIds` and all three boundary tests converted to direct calls. `isTenantTransactional` keeps reflection — it needs `getAnnotation`.

#### A verify-script defect found during sign-off

The first full run reported `34 pass, 5 fail` with every `mvn` row red, while those same classes passed on their own. Cause: the helper inherited from `verify-plan-template.sh` pipes `mvn -q` into `grep -qE "BUILD SUCCESS|Tests run..."`, but `-q` suppresses INFO output — maven exits 0 having printed neither string, so the row can never pass. Measured: exit 0, 1223 bytes, zero matches for either pattern.

Rewritten here to use the exit code plus a required surefire summary (so a run that executed no tests still fails). **This is a template-level defect: every verify script carrying `mvn_test_passes` has permanently-red `mvn` rows.** Worth fixing in `sbdocs/9-System/templates/verify-plan-template.sh` under its own ticket.

#### Code review — production lane, 2026-08-19

Independent `code-reviewer` lane over `git diff -- src/main/java`. Verdict: the core is correct — no input produces a wrong final row set, the transaction annotation is character-for-character the form `CLAUDE.md` prescribes, all three repository calls join the outer transaction so atomicity genuinely holds, and no remaining transposed or wrong-column site exists. Every load-bearing claim below was re-verified first-hand before being accepted.

**H1 — `saveRoleFunctions` is an ungated write to the access-control table. RECORDED, NOT FIXED HERE (see rationale).**

`/v3/**` requires only `hasAnyAuthority("wms_user")` (`SecurityConfiguration.java:151`), and `UserRoleController` carries no function guard — unlike `UserController:311`, which SBDEV-2870 gated with `denyUnlessUserManagementAllowed()`. `mywms_role_mywms_function` is the *next* join in the same chain `UserRepository.getAllRoles` walks (`UserRepository.java:27-34`), so any `wms_user` can self-escalate: create a role → grant it `WEB_UI_VIEW_USER_MANAGEMENT` → attach it to a group they belong to (`UserGroupController:99-116`, also ungated) → they now pass the SBDEV-2870 gate. This is the self-grantable-gate problem, one join further along.

**Why this is not fixed in this ticket, deliberately:**

1. **A controller guard would be insufficient, and would therefore mislead.** `UserRoleUserFunction` is in `RestConfiguration.java:40`'s `exposeIdsFor`, so `POST /v3/userRoleUserFunction` writes the table directly; and `UserRole.functions` gives `PUT/PATCH/DELETE /v3/userRole/{id}/functions` (plan §4). Both bypass any controller-level check, under the same `wms_user` authority. Adding one line to the controller would close the least important of three doors while reading like the problem was handled.
2. **The capability predates this diff.** Those two HAL surfaces work today, on unfixed `develop`. This change does not create the escalation; it makes the *UI* path work, which is a marginal convenience increase over an already-open capability.
3. **It is SBDEV-2967 / SBDEV-2968's scope, and they are mid-design.** SBDEV-2968 is building a `@RequiresFunction` annotation plus an interceptor. An ad-hoc guard added here would have to be reconciled with that mechanism, and §12.2 deliberately keeps this diff off those files.

**What must not happen is this going unrecorded**, which is why it is here, in §12.3, and in the follow-up alongside §12.2's deferrals. Closing the HAL surfaces needs `@RestResource(exported = false)` — precedent at `MessageRepository.java:32,42`, added for exactly this reason — and that is a published-API change deserving its own ticket.

**M2 — every malformed payload yields a bare 500 with no body. FIXED.** Four inputs reach an unhandled exception: missing/null `roleId` (NPE), missing `functions` (NPE), non-array `functions` (CCE on the erased cast), and any id > `Integer.MAX_VALUE` (Jackson binds `Long`, so `(Integer)` casts blow up). `RestEndpointExceptionHandler` is scoped `@ControllerAdvice(basePackages = "net.aim_ai.wms.controller.rest")` (`:37`) and this controller is in `net.aim_ai.wms.controller`, while the global `RestExceptionHandler` has no `Exception` handler — so these fall through to DispatcherServlet's `/error`. Not a regression, but the diff rewrote precisely these lines and the 422 mechanism already exists (`RestExceptionHandler:35-40` maps `ApiInvalidParameterException`).

**The justification is API hygiene, not user-visible improvement.** An unhandled 500 for a malformed request is untyped, cannot be logged as a client error, and is indistinguishable from a genuine server fault in monitoring — that stands on its own. It does **not** improve what the operator sees: `wms2-web-ui/store/admin/role.js:74-77` catches every rejection into one generic "network or server issue" toast, so a 422 with a `ProblemDetail` body changes nothing on screen until the UI is changed to read the body. That UI change is out of scope here; recorded so nobody claims a user-facing win from this.

**M3 — unknown `roleId` yields a 500, or worse a silent `200` when `functions` is empty. FIXED.** `findByRolelistId` on an unknown role returns empty, then each insert violates the FK → 500. With `functions: []` both loops no-op and the caller gets `true` for a role that does not exist. Validated in the **controller** via `userRoleRepository.existsById(roleId)`, which satisfies §5 Fix D's prohibition on loading `UserRole` inside the transaction: `existsById` never materializes the entity, so the EAGER `functions` collection is never instantiated.

**L4 — the closing `LOG.debug` did three stream passes purely for a log message. FIXED** by counting inside the two existing loops. SLF4J's parameterized form avoids concatenation, not argument evaluation, so those `.count()` terminal ops ran at every level.

**L5 — `throws WebserviceBusinessExceptionClientSide` on `saveRoleFunctions` is now unreachable.** Left in place: nothing throws it and no advice keys on it, but it matches every sibling controller's habit and removing it is churn.

**L6 — `findByFunctionlistId` has zero production callers after Fix F.** Kept: it is a legitimate reverse lookup and is exported at `/v3/userRoleUserFunction/search/findByFunctionlistId`; `exported = false` would change the published HAL surface for no gain. Noted here so a later reader does not infer something depends on it.

**L7 — `save()` resolves to `merge()`, so each newly-added row costs one extra `SELECT`.** Unavoidable with an assigned `@EmbeddedId` and no `@Version`; bounded by the function count of one role. No action.

**Manual-QA note worth carrying:** all six `AccessService` function-edge methods (`addFunctionTo*` / `removeFunctionFrom*`) have **zero live callers** — their only call sites are in the unroutable `UtilRestController` — so **Fixes C and F are correctness-only with no observable behaviour change.** Do not expect them to show up in manual testing.

#### Code review — test lane, 2026-08-19

Independent adversarial lane whose brief was one question: *would these tests fail if the bug came back?* It ran real mutants in a throwaway copy and **measured** each result. Two High, four Medium, five Low. Every fix below was re-verified by mutation here before being accepted.

**HIGH-1 — a mutant strictly WORSE than the unfixed code was 100% green. FIXED.** Changing the annotation to `propagation = NOT_SUPPORTED, readOnly = true` passed all 71 tests and produced `34 pass, 0 fail` on the verify script, with D2 green. `NOT_SUPPORTED` suspends the transaction, restoring the entire secondary defect Fix D exists to close; `readOnly = true` sets `FlushMode.MANUAL` on a `JpaTransactionManager`, so the deletes and inserts never flush and saving role functions becomes a **silent no-op returning `200 true`**.

Every guard missed it for a different reason: `isTenantTransactional` read only `tx.value()`; the boundary test could not see it because `TransactionAspectSupport` calls `getTransaction(txAttr)` for *every* propagation and `rollback(status)` unconditionally, so against a **mock** manager `REQUIRED`, `SUPPORTS`, `NOT_SUPPORTED` and `NEVER` are indistinguishable and `readOnly` lives on the definition the mock discards; and D2's tempered gap forbids only `;` and `@`, which `propagation = …, readOnly = true)` contains neither of.

Closed on three fronts — `isTenantTransactional` now asserts `propagation` and `readOnly`; `transactionDefinitionIsAWritableRequiredTransaction` captures the `TransactionDefinition` and asserts `PROPAGATION_REQUIRED` and `!isReadOnly()`; verify `T1` was repurposed to require those assertions exist. **Re-measured: the mutant now fails in both lanes.**

**HIGH-2 — "clear every function from a role" was covered nowhere. FIXED.** Existing non-empty + desired empty. Every service test used a non-empty desired set, and the one `List.of()` call stubbed an empty existing set, so a plausible defensive guard (`if (functionIds.isEmpty()) return;` — "don't wipe a role by mis-click") was measured green across the whole suite. Added `clearsAllAssignmentsWhenDesiredIsEmpty`; **re-measured: that guard now fails.** Clearing is legitimate and the endpoint deliberately permits it, so the payload validation does **not** reject empty arrays — recorded because it is a decision, not an accident.

**MEDIUM-3 — AC-13's three cited verify rows were decorative. FIXED.** Against a real delete-all-then-reinsert body, `doesNotChurnUnchangedAssignments` correctly failed while D5, D7 and D8 all passed: D5 required only the substring `contains(`, which a surviving log line satisfied. D5 now requires **both** guarded branches (`if (!desired.contains(` and `if (!existing.containsKey(`); **re-measured: D5 now fails on that mutant.** AC-13's citation is corrected to name the unit test as the real guard.

**MEDIUM-4 — a legal, semantically identical spelling was a FALSE RED with a misleading message. FIXED.** `@Transactional(transactionManager = "tenantTransactionManager", …)` — `transactionManager` is `@AliasFor("value")`, so Spring resolves it correctly, but raw `getMethod().getAnnotation()` returns `value() == ""`, so `isTenantTransactional` failed *and pointed the reader at the landlord theory*, which would be wrong. Switched to `AnnotatedElementUtils.findMergedAnnotation` and widened D2 to accept both spellings; **re-measured: the alias now passes.**

**MEDIUM-5 — AC-8 was cited to a row that cannot fail. FIXED.** `T1` matched the string `ArgumentCaptor` in either test file, and the controller test contains `ArgumentCaptor<Long>` for payload widening — so T1 stayed green even if the entire `ReplaceRoleFunctions` class were deleted. AC-8 now cites T2+T3, both confirmed to depend solely on the service test.

**MEDIUM-6 — a test asserted a property Hibernate does not honour. DELETED.** `removalsBeforeAdditions` asserted `delete` was *called* before `save`, but this method's own javadoc states that Hibernate's `ActionQueue` emits inserts before deletes regardless of call order — so swapping the loops produces byte-identical SQL. It could not go red on a real defect, could go red on a harmless reordering, and its name read as a guarantee about SQL order, the opposite of the truth. Removed, with a comment in its place; the same defect as the earlier `deletesBeforeSaves`.

**AREA 4 — two more holes in `mvn_test_passes`, both measured. FIXED.** (a) `Skipped:` was unchecked, so a class-level `@Disabled` reports `Tests run: 1, Failures: 0, Errors: 0, Skipped: 1` with exit 0 and certifies itself green — meaning M5, the row carrying AC-5, would survive its own test class being disabled. (b) `Tests run: 0` matched `[0-9]+`: because every test lives in an `@Nested` class, surefire also emits a `Tests run: 0` line for the *outer* class, so deleting the nested classes still passed. Now requires `Skipped: 0` and a per-class minimum (17/8/39/13/3, taken from this sign-off run). The script also now restores the ArchUnit freeze store that the maven rows mutate.

**LOW, accepted without code change:** T6 was satisfiable by the class javadoc alone → retied to the actual `verify(...)` assertions. `rollbackFor` is dead configuration (nothing throws either exception) but is the canonical form in `CLAUDE.md`. Verify rows A4/C1/D5/D8/D9 anchor on identifier names and would false-red on a rename. D1/D4 are comment-satisfiable but backed by D2/D6/A4. `doReturn(...).when(repo).findByFunctionlistId(...)` would slip past T5's `when\(repo\.` regex.

**What the lane confirmed sound:** the composite-key orientation tests — the ones guarding the reported bug — with no green mutant constructible for any of them. Also: `doesNotChurnUnchangedAssignments` verified red against four separate mutants; the shared Spring context plus `reset()` is safe because surefire runs methods sequentially (no `parallel` in `pom.xml:445-461`); the `@Primary` landlord mock is faithful to production (`LandlordDatabaseConfig.java:61`); and no verify row is permanently red, with D6 and D9's tempered gaps correctly scoped.

#### Still open

- **P2 — prd `wh01_hydra_v2` audit.** The prd MCP is registered but connects as `wh03_om1`, which can read 0 of 55 `public` tables (objects are owned by `wh01_hydra_v2_app`, and there is no role membership between them). Needs a role with SELECT before the one read-only query can run. Does not affect any line of the code fix — only whether a data-repair step is warranted.
- **Manual tests M1–M5, M7, M8** — not run; no tenant session was exercised. **M4 and M8 are the only evidence for AC-5 end-to-end and AC-13 respectively.** M4 must post a set that DROPS an existing function, or the delete set is empty and the test proves nothing.
- Not committed, no PR.

---

## 14. Follow-ups — filed 2026-08-19

Consolidated here because these were previously scattered across §0, §5, §6, §12.2, §12.3 and §13.4, which made the set impossible to see at a glance and meant archiving this plan would bury them.

| # | Ticket | Item | Priority |
|---|---|---|---|
| 1 | [SBDEV-3010](https://app.clickup.com/t/868kua912) | The migrations declare **no uniqueness** on the four authorization join tables, and `mywms_user_mywms_role` has **no index at all** | normal |
| 2 | [SBDEV-3011](https://app.clickup.com/t/868kua92j) | `deletRole` leaves group→role / user→role rows behind → **live 500** on deleting any assigned role, and strips its functions first because the deletes are not transactional. **Planned 2026-08-20 — `SBDEV-3011-delete-role-join-table-cascade.md`.** DB-verified on `wms2-hydra-uat`: all 14 of 14 roles are held by a group, so `roles_deletable_today = 0` — the endpoint is broken for *every* role, and `super-admin` loses 77 grants across 16 groups per attempt | high |
| 3 | [SBDEV-3012](https://app.clickup.com/t/868kua93r) | `saveGroupRoles` / `saveUserGroups` — the same non-atomic delete-then-insert; a partial failure wipes a subject's assignments | high |
| 4 | [SBDEV-3013](https://app.clickup.com/t/868kua9b6) | Spring Data REST exposes the role↔function join table, so a **controller guard cannot close the escalation** | high |
| 5 | [SBDEV-3014](https://app.clickup.com/t/868kua9c9) | `verify-plan-template`'s `mvn_test_passes` reports FAIL on every passing run — **62 red rows across 22 scripts** | normal |

**Folded into SBDEV-2967 rather than filed separately:** the controller-side half of the H1 ungated-write finding — annotating `saveRoleFunctions` and `saveGroupRoles` once SBDEV-2968 lands `@RequiresFunction` + `FunctionGuardInterceptor`. SBDEV-2968 §13.2 states the mechanism is platform-wide while its coverage is not, and names SBDEV-2967 as the widener. Neither plan currently mentions these endpoints (zero grep hits for `saveRoleFunctions`, `saveGroupRoles`, `UserRoleController`, `UserGroupController`), so this is a genuine scope addition, cheap while 2967 is still in draft.

**Not filed — v1.** §6 confirms Bugs 2 and 3 exist byte-for-byte in `v1/.../RoleController.java:82-102`. Per Nam's 2026-08-19 direction, v2 only; the finding stays as an observation.

**Sequencing note:** SBDEV-3012 and the SBDEV-2967 scope addition touch the *same two methods*. Different defects with different acceptance criteria, so they stay separate — but whoever goes second will be editing files the first just changed.

**On SBDEV-3010's re-scope:** it was first filed as "add PRIMARY KEYs" at `high`. That overstated it — Java uses `@EmbeddedId` for these tables, and three of the four already carry UNIQUE composite indexes on live tenants, so a primary key would add little. What survives is that the *migrations* declare no uniqueness at all (every unique index in the estate is out-of-band), that `mywms_user_mywms_role` has no index anywhere, and that concurrent check-then-act across replicas is the one case `@EmbeddedId` cannot cover. Re-scoped and dropped to `normal`.
