---
ticket: SBDEV-3012
lane: test adequacy (mutation testing / vacuous assertions / coverage gaps)
repo: v2/wms2-api
pr: "#182"
reviewed_at: 2026-08-21
reviewed_range: "51d8c09 (as briefed) → 0a3589f (HEAD at time of writing)"
verdict: SHIP WITH FIXES
---

# SBDEV-3012 — review lane: test adequacy

## Verdict

**SHIP WITH FIXES.** One **High** finding (two mutants, one per service, that silently reproduce
the exact data loss this ticket exists to prevent and are invisible to the entire 5415-test suite)
plus four Medium. Everything else I probed is genuinely well covered — this is, measured, one of the
better-tested changes in this repo: **91 of 104 mutant runs were killed**, including every
`@Transactional` attribute, every composite-key argument order, every `existsById` guard, and every
set-difference branch.

Nothing I found is a correctness defect in the shipping code. Every finding is *a test that cannot
fail*, so the risk is entirely about the next edit, not this one.

### Moving-target caveat (read this first)

The worktree changed **three times while I was measuring it**. The brief named head `51d8c09`; the
author landed `060d4ed` and `0a3589f` mid-review, plus uncommitted edits in between, in response to
other lanes. Consequences:

* Findings I originally measured as open and the author has since **closed**: the `deleteGroup`
  bulk-delete ordering (my `D03`, their "review finding M-2"), the five bulk-delete JPQL strings
  (`Q01`–`Q03`, closed by the new `UserGroupQueryContractUnitTest`), and both request caps
  (`C01`/`K01`). I re-ran all of them against `0a3589f` and they are now **KILLED** — the fixes are
  real, not just present. Rows are kept in the table below with both verdicts so the history is
  auditable.
* **I mutated the shared worktree for batches 1–3** before I noticed. I also ran
  `git checkout -- src/main/java/net/aim_ai/wms/service/UserGroupService.java` twice. If any author
  edit to `UserGroupService.java` or `UserService.java` was in flight in that window it may have been
  clobbered and re-done. From batch 4 on I worked in a private `tar`-copy at
  `/tmp/.../scratchpad/iso2`. **Process fix for future parallel review lanes: reviewers who mutate
  must copy the tree first.**
* Everything reported as **open** below was re-confirmed against `0a3589f`.

### Suite baselines (measured, isolated copy of `0a3589f`)

| Run | Result |
|---|---|
| Full suite | **5415 run, 2 failures, 67 skipped** |
| The 2 failures | `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses` (6 violations: `PickLineRealignmentService:80,81`, `ReplenishGeneratorService:210`, `UnitloadBusinessService:751,755`, `MobileReplenishService:1024` — **none in this diff**) and `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`. Both pre-existing on `develop`. |
| Ticket subset (6 classes) | 88 run, 0 failures |
| Delta vs. the briefed 5407 | +8, exactly the new `UserGroupQueryContractUnitTest` |

**No new failures, no regressions.**

---

## Findings

### H-1 — A stray bulk clear in either `replace*` method is completely invisible (mutants `X01b`, `X03b`)

`src/main/java/net/aim_ai/wms/service/UserGroupService.java:184` (`replaceGroupRoles`)
`src/main/java/net/aim_ai/wms/service/UserService.java:236` (`replaceUserGroups`)

Insert one line at the top of either method:

```java
userGroupUserRoleRepository.deleteByGroupId(groupId);   // in replaceGroupRoles
userGroupUserRepository.deleteByUserId(userId);         // in replaceUserGroups
```

Both mutants **SURVIVE the entire suite**. In production each one wipes every existing grant and then
re-adds only the *difference*, so every retained role/membership is destroyed — i.e. precisely the
"group detached from every role" / "user in no group" outcome the set difference exists to prevent,
and the outcome the PR's own javadoc calls "a total, silent loss of access."

This is not a hypothetical shape. It is the **most likely future edit** to these methods: the author's
own new comment on `replaceGroupRoles` explains that no Flyway-provisioned tenant has a unique index
on these tables, so a clear-then-reinsert **does not fail loudly** — it silently duplicates or
silently loses. A maintainer who reads "clear-then-reinsert used to work" and simplifies accordingly
gets a green build.

Why the existing minimality tests miss it: `replaceGroupRolesIsANoOpWhenNothingChanged` and
`replaceUserGroupsIsANoOpWhenNothingChanged` assert `never()).delete(any())` and `never()).save(any())`
— the **entity-level** methods. The bulk methods are a different signature on the same mock and are
unverified. `replaceGroupRolesDoesNotTouchMemberships` does assert
`verify(userGroupUserRepository, never()).deleteByGroupId(anyLong())` — but on the *sibling* repository,
not the one `replaceGroupRoles` writes.

**Fix** — in `UserGroupServiceTransactionBoundaryTest.replaceGroupRolesTouchesOnlyTheDifference` and
`replaceGroupRolesIsANoOpWhenNothingChanged`:

```java
verify(userGroupUserRoleRepository, never()).deleteByGroupId(anyLong());
```

and in the two `UserServiceTransactionBoundaryTest` siblings:

```java
verify(userGroupUserRepository, never()).deleteByUserId(anyLong());
```

Both are one line and both kill the mutant. (A `verifyNoMoreInteractions` on the repository mock after
the expected calls would cover this and H-2 and M-3 at once, but is more brittle; the targeted
`never()` is the better trade here.)

---

### M-1 — `deleteUserDoesNotCascadeOperationalHistory` cannot detect a cascade (mutant `X08b`)

`src/test/java/net/aim_ai/wms/unit/service/UserServiceTransactionBoundaryTest.java:349-361`

The test is named "deleteUser does NOT cascade beyond group memberships" and its javadoc pins it as
"the scope boundary so a future 'completeness' edit has to argue with a test." Its actual body is:

```java
verify(userGroupUserRepository, times(1)).deleteByUserId(35L);
verify(userGroupUserRepository, never()).deleteByGroupId(anyLong());
```

Adding `printerRepository.deleteById(userId);` to `UserService.deleteUser` **SURVIVES**. So does any
other cascade through any of the other eight collaborators (`clientRepository`, `locationRepository`,
`locationService`, `userGroupRepository`, …). The `never().deleteByGroupId` line is a wrong-axis guard,
already redundant with the `times(1)` above it, and it is the only "does not cascade" content in the
test. The name and javadoc claim protection the assertions do not provide — the failure mode this repo
has recorded before (a test that reads as a scope pin and is actually vacuous for that purpose).

Note the nine operational `operator_id` FKs are genuinely un-assertable at this level — `UserService`
holds no repository for `pickingorder` etc., so no cascade *through them* is even expressible. That
half is a real coverage limit (see "What nothing can catch"), not a fixable assertion.

**Fix** — make the claim as broad as the name:

```java
verifyNoMoreInteractions(userGroupUserRepository, userRepository);
verifyNoInteractions(printerRepository, clientRepository, userGroupRepository,
        locationRepository, locationAreaRepository, locationTypeRepository, locationService);
```

(the `verifyNoInteractions` list needs those beans `@Autowired` into the test, which they currently
are not — three extra fields). Alternatively rename the test to
`deleteUserClearsMembershipsExactlyOnceOnTheUserAxis`, which is what it actually proves. Either is
acceptable; silently keeping the current name is not.

---

### M-2 — `UserController` has no missing / null / non-numeric `userId` test (mutant `C07c`)

`src/main/java/net/aim_ai/wms/controller/UserController.java:455-460` (`requiredId`)

Replacing the whole guard with a bare cast —

```java
private static Long requiredId(Object raw, String field) { return ((Number) raw).longValue(); }
```

— **SURVIVES**. In production a body of `{"groups":[1]}` (no `userId`) then throws
`NullPointerException` from `UserController`, whose package is not covered by
`RestEndpointExceptionHandler`, producing exactly the bare bodyless 500 the PR set out to remove.

`shouldRejectANonArrayGroups` never reaches `requiredId` with a non-Number (the `instanceof List`
check fires first), and nothing else feeds it one. This is an asymmetry, not an oversight of taste:

| Endpoint | missing id | null id | non-numeric id |
|---|---|---|---|
| `UserRoleController.saveRoleFunctions` (merged precedent) | ✅ `missingRoleId` | ✅ `nullRoleId` | ✅ |
| `UserGroupController.saveGroupRoles` (this PR) | ✅ `rejectsAMissingGroupId` | — | — |
| `UserController.saveUserGroups` (this PR) | ❌ | ❌ | ❌ |

**Fix** — copy `UserRoleControllerUnitTest:281-300` (`missingRoleId` / `nullRoleId`) with `userId`.
Six lines, and it kills `C07c`.

---

### M-3 — the child-id existence lookup is stubbed argument-agnostically, so "which ids were queried" is unpinned (mutant `Y03`)

`src/test/java/net/aim_ai/wms/unit/controller/UserControllerUnitTest.java:436, 466, 500`
`src/test/java/net/aim_ai/wms/unit/controller/UserGroupControllerUnitTest.java:178, 274`

Every stub of the new child-id check is `when(...findAllById(any())).thenReturn(...)`. Changing the
controller to `findAllById(java.util.List.<Long>of())` — i.e. querying nothing and therefore treating
**every** requested id as unknown — **SURVIVES**, because `any()` matches regardless. In production
that mutant 422s every legitimate save.

Same defect on both controllers. It is the "stub matches anything, so the argument is untested" shape.

**Fix** — either stub on the exact argument:

```java
when(userGroupRepository.findAllById(java.util.List.of(10L, 20L, 30L)))
        .thenReturn(java.util.List.of(group(10L), group(20L), group(30L)));
```

or keep `any()` and add `verify(userGroupRepository).findAllById(java.util.List.of(10L, 20L, 30L));`.
The second is preferable — it also pins the `distinct()` widening.

---

### M-4 — the `delet()` catch clause is unpinned, so widening it is free (mutant `C13b`)

`src/main/java/net/aim_ai/wms/controller/UserController.java:364`

Widening `catch (DataIntegrityViolationException e)` to `catch (DataAccessException e)`
**SURVIVES**. That mutant does not break the 404 (`EntityNotFoundException` is a plain
`RuntimeException`, not a `DataAccessException`), but it converts *any* transient database fault —
deadlock, connection loss, statement timeout — into
`422 "User N cannot be deleted because they are still referenced by other records"`, a confidently
wrong reason. It is also the exact drift the author's own 13-line comment at that site worries about
("Naming only the first would give a confident wrong reason for the other two"), and nothing enforces
it.

Note that `catch (DataAccessException e)` is what the **pre-fix** code had, so a future revert is a
plausible path here, not a contrived one.

**Fix** — one test: `doThrow(new org.springframework.dao.QueryTimeoutException("boom"))
.when(userService).deleteUser(1L);` then assert the exception propagates as
`QueryTimeoutException`, **not** `ApiInvalidParameterException`.

---

### Low findings

| id | file:line | Surviving mutant | Note / fix |
|---|---|---|---|
| **L-1** | `UserController.java:388` | `C14b` — success body `" DELETED"` → `" ok"` | `shouldDeleteUserSuccessfully` asserts only `status().isOk()`; the group-controller sibling *does* assert `containsString("DELETED")`. Confirmed harmless today: `wms2-web-ui/store/admin/user.js:110` never reads the body. Add `.andExpect(content().string(containsString("DELETED")))` for symmetry, or accept it as deliberately unspecified. |
| **L-2** | `UserController.java:381-383` | `C15` — one-arg `ApiInvalidParameterException` reverted to the two-arg field form | The author added 13 lines of comment arguing the one-arg overload is deliberate (so the body is a renderable `{"error": …}` rather than `{"error":"Parameter error", parameterErrors:[…]}`). `hasMessageContaining("cannot be deleted")` passes either way, so the decision is unenforced. Assert on `getErrorObject()`'s type or `getFieldName() == null`. |
| **L-3** | `UserController.java:340`, `UserGroupController.java:166` | `C02c`, `K02c` — cap boundary `>` → `>=` | The new cap tests use 501 items, so exactly-500 is never exercised and the off-by-one is free. The merged precedent (`UserRoleControllerUnitTest:392`) has the same weakness. Add a 500-item accepted case, or accept as immaterial. |
| **L-4** | `UserGroupUserRoleRepository.java:52` (and the 4 siblings) | `Q10b` — `@Modifying(flushAutomatically = true)` → `@Modifying` | `UserGroupQueryContractUnitTest` asserts `clearAutomatically() == false` but says nothing about `flushAutomatically`. Not load-bearing for today's two callers (neither has pending entity changes when the bulk statement runs) but it is asymmetric with the sibling assertion. One line in `assertBulkDeleteContract`. |
| **L-5** | `UserController.java:337` | `C16` — an empty `groups` array is rejected | The javadoc explicitly says an empty array is a legitimate "revoke every group". `UserGroupControllerUnitTest.acceptsAnEmptyRoleList` pins the equivalent on the group side; `UserController` has no such test. Six lines. |
| **L-6** | `UserGroupService.java:171`, `UserService.java:214` | `G03`, `U03` — `rollbackFor` removed | **Not a defect.** `BusinessException`/`FacadeException` are checked and neither method declares them, so the attribute is inert. The author documented exactly this in a comment on `replaceGroupRoles` during the review. Recorded only so the survivor is explained rather than unexplained. |
| **L-7** | `UserController.java:451` | `Y02` — `.distinct()` dropped | Behaviour-equivalent (only affects how many ids one `findAllById` is handed). Informational. |

---

## Vacuous-assertion audit

The brief asked specifically whether the author caught every `never()` verify that went vacuous when
the writes moved from the controllers into the services. **He did, and he labelled them honestly.**

* `UserControllerUnitTest:582-590` — the retargeting comment is explicit: *"THIS ASSERTION HAD TO
  MOVE … the three repository `never()` verifies below became VACUOUS: they pass whether the guard
  fires or not. The load-bearing assertion is the one on `userService`."* Verified by mutant `C12b`
  (gate moved after the service call) → **KILLED** by `shouldDenyWithoutTheUserManagementFunction`
  and `shouldDenyAnonymousWithoutReadingTheFunction`. The added
  `verify(userRepository, never()).existsById(anyLong())` is genuinely load-bearing.
* `UserControllerUnitTest:727` (`UngatedWriteEndpoints`) — same retargeting, same honest comment.
  Mutant `C11` (gate moved after the service call in `delet`) → **KILLED** by `deleteIsGated`.
* `UserGroupControllerUnitTest:143-148` — `never()).delete(...)` / `never()).deleteById(...)` kept as a
  "controller keeps no direct write path" check. **Not vacuous**: mutant `X05` (controller regrows
  `userGroupRepository.deleteById(groupId)` after the service call) → **KILLED**. Note the stronger
  protection is structural, not the test — both controllers had the join-table repositories *removed
  from their constructors*, which makes most of this class of regression uncompilable.
* `membershipIdIsBuiltInDeclaredOrder`
  (`UserGroupServiceTransactionBoundaryTest.java:410-416`) — genuinely vacuous with respect to
  production code: it constructs a JDK record and reads its accessors. It is labelled *"Keeps the
  unused-import checker honest"* / *"sanity:"*, so it is honestly presented as non-load-bearing.
  **No action.** The real key-order pin is `replaceUserGroupsBuildsTheCompositeKeyInDeclaredOrder`,
  which mutant `U04` confirms **KILLS** a swap.
* `shouldPropagateNotFound` (`UserControllerUnitTest:414`) — near-vacuous as written (it only proves
  the `catch` does not swallow a `RuntimeException` that is not a `DataAccessException`). It is not
  *wrong*, and mutant `C13b` shows what would make it load-bearing — folded into M-4.
* `UserGroupQueryContractUnitTest` — checked for the "reflection loop over an empty list" failure
  mode. **It is not vacuous**: the `method()` helper throws `AssertionError` on a missing method, the
  lookup is keyed on **name + arity** (with a comment saying why), and I killed it with seven
  independent mutants (`Q01`–`Q09`). The one thing it does *not* assert is `flushAutomatically`
  (L-4).

**Found nothing** in these areas: no assertion satisfied by a comment; no `hasMessageContaining` on
an always-present string that I could keep alive with a mutant (`C10` and `Y01` both die on their
message assertions); no absence-assertion absorbed by a sibling fix's early return.

---

## Order dependence and shared-context isolation

Asked because the two new classes share a Spring context and one of the author's tests was briefly
order-dependent during development.

* Both `@BeforeEach` blocks `reset(...)` every mock they later stub or verify, and re-create
  `tenantStatus` per test. `UserGroupServiceTransactionBoundaryTest` resets 5 of its 7 mocks —
  `clientService`, `basicService` and `clientRepository` are unreset, but no test in the class stubs
  or verifies them, so nothing can leak. `UserServiceTransactionBoundaryTest` resets the 4 it uses out
  of 12. **Complete for what they touch.**
* Each of the five classes run **alone**: 15 / 13 / 8 / 29 / 10, all green.
* All six together under **random method order and random class order**, seeds 11 / 22 / 33: 88 run,
  0 failures, three times. I verified the randomiser actually engaged by diffing `<testcase>` order in
  the surefire XML between seeds (it is not declaration order) — so this check is not itself vacuous.
* Five consecutive identical clean runs of the subset: 76/76 green each time (pre-`060d4ed` tree).

**Found nothing.** No order dependence.

One honest caveat: during batch 1 and batch 3 I saw two anomalous runs whose only failures were in
classes the mutant could not reach (`UserControllerUnitTest$UngatedWriteEndpoints.deleteIsGated`
once, `UserGroupServiceTransactionBoundaryTest.deleteGroupClearsBothJoinTables` once). Neither
reproduced in isolation — `G03` was green twice more standalone, and 3 random-order runs plus 5 clean
repeats are green. Both anomalies fall inside the window in which the author was editing the shared
worktree, which recompiles mid-run. I attribute them to that, not to a flake, but I could not prove it
after the fact.

---

## What nothing can catch automatically

Answering the brief's question plainly.

1. **~~The five bulk-delete JPQL strings~~ — CLOSED during the review.** This was my finding; another
   lane found it too. `UserGroupQueryContractUnitTest` (new, 8 tests) now pins each query string by
   reflection. I confirmed it kills all three valid-but-wrong-field swaps
   (`grouplistId`↔`rolelistId`, `grouplistId`↔`userlistId` both ways) plus wrong-entity and wrong-column
   variants. The class's own javadoc states its limit correctly: it proves the strings say what the
   design says, not that they parse or delete the right rows.
2. **That the JPQL parses and targets the right columns against a real schema — still nothing.**
   No `@DataJpaTest` exists anywhere in `src/test` (verified); SBDEV-2217 has the Testcontainers lane
   down. In practice a wrong *field name* fails loudly at Spring Data repository-factory
   initialisation, i.e. at application boot, so the only silent class is the valid-but-wrong field —
   which item 1 now covers by string. **Manual substitute:** boot against a tenant (the repository
   factory validates all five `@Query` strings eagerly) and then exercise each of the four endpoints
   once against `wms2-hydra-uat`, checking row counts in `mywms_group_mywms_role` and
   `mywms_group_mywms_user` before and after.
3. **The nine operational `operator_id` FK behaviours — nothing, by construction.** `UserService`
   holds no repository for `pickingorder`, `billoflading`, etc., so "does not cascade audit history"
   is not expressible at unit level (M-1). The `DataIntegrityViolationException` path is *simulated*
   in `deleteUserRollsBackWhenOperationalHistoryBlocksTheDelete`, which is the right test for the
   rollback but proves nothing about whether the real FK actually fires. **Manual substitute:**
   `GET /v3/user/delete/{id}` for a user with picking history on hydra-uat → expect 422, then confirm
   `SELECT count(*) FROM mywms_group_mywms_user WHERE userlist_id = {id}` is **unchanged**. That single
   check is the whole ticket and no automated lane can perform it.
4. **The actual rollback — nothing.** Every transaction test mocks `PlatformTransactionManager`, so
   they prove the *boundary* (right manager, `REQUIRED`, not `readOnly`, `rollback()` called with the
   right status) but never that a database rolls anything back. This is the accepted repo-wide
   limitation of the `UserRoleServiceTransactionBoundaryTest` pattern and is the correct trade while
   SBDEV-2217 is open; item 3's manual check is what substitutes.
5. **Concurrency — nothing, and the author now says so in the code.** The mid-review comment on
   `replaceGroupRoles` states that no Flyway-provisioned tenant has a unique index on either join
   table, so two simultaneous callers adding the same id both insert and nothing rejects the second.
   No unit test can reach that. Correctly scoped out (it needs a unique index plus a de-duplicating
   migration); worth carrying forward as a known limit rather than being re-discovered.
6. **`GET /v3/userGroup/delete/{groupId}` is unreachable from the web UI** — so "click delete in the
   UI" is *not* an available manual check for `deleteGroup`. `deleteGroupPop.vue:38` dispatches
   `admin/userGroup/deleteGroup`, and there is no `store/admin/userGroup.js` (the module is
   `store/admin/group.js`, i.e. `admin/group/deleteGroup`). It is the only `admin/userGroup` dispatch
   in the repo. **Pre-existing and outside this diff** — flagged only because it changes how item 3's
   manual verification must be performed (direct API call, not the UI), and because the delete-group
   half of this ticket therefore has no user-facing regression path at all. Worth confirming with
   whoever owns the UI before treating it as a defect.

---

## Full mutant table

104 runs, 100 distinct mutants. Harness: `/tmp/claude-1000/.../scratchpad/mutants.py` + `m1`–`m8.json`
(kept). Design notes, since the brief flags the mtime trap the author's first attempt fell into:

* originals held **in memory as strings**; restore is a plain `open(...,'w')` write, never
  `shutil.copy2`/`move`, and every write is followed by an explicit `os.utime(path, None)` — so javac
  always sees a source newer than the previous mutant's `.class`
* an anchor that does not match **exactly once** aborts that mutant as `ANCHOR_MISMATCH`; it is never
  silently reported as a pass
* `COMPILATION ERROR` is classified separately, never as a kill
* verdicts come from the surefire `Results:` counters, not from log scraping
* **positive control `PC1`** (remove `@Transactional` outright) confirms the harness kills what it
  should — had the mtime trap been present, `PC1` would have shown SURVIVED

Reproduce:

```bash
export JAVA_HOME=~/.sdkman/candidates/java/current
export PATH="$JAVA_HOME/bin:$HOME/.sdkman/candidates/maven/current/bin:$PATH"
# copy the tree first — do NOT mutate a worktree someone else may be editing
tar -C <worktree> --exclude=./target --exclude=./.git -cf - . | tar -C /tmp/iso -xf -
mvn -o test -Dtest='UserGroupServiceTransactionBoundaryTest,UserServiceTransactionBoundaryTest,\
UserControllerUnitTest,UserGroupControllerUnitTest,UserGroupServiceUnitTest,UserGroupQueryContractUnitTest' \
  -DfailIfNoTests=false -Djacoco.skip=true
```

### `UserGroupService.replaceGroupRoles`

| id | mutant | verdict | killed by |
|---|---|---|---|
| PC1 | **positive control** — `@Transactional` removed outright | KILLED | 3 × `UserGroupServiceTransactionBoundaryTest` |
| G01 | bare `@Transactional` (binds `@Primary` landlord manager) | KILLED | `failingSaveRollsBackOnTenantManager`, `successfulReplaceCommitsOnTenantManager`, `…TransactionDefinition…` |
| G02 | `propagation = NOT_SUPPORTED, readOnly = true` | KILLED | `replaceGroupRolesTransactionDefinitionIsAWritableRequiredTransaction` |
| G03 | `rollbackFor` removed | **SURVIVED** | — (L-6, inert by design) |
| G04 | set difference → delete-all-then-reinsert-all | KILLED | `replaceGroupRolesTouchesOnlyTheDifference`, `…IsANoOpWhenNothingChanged` |
| G05 | `existing` keyed on `grouplistId` instead of `rolelistId` | KILLED | 3 tests |
| G06 | composite key swapped: `UserGroupUserRoleId(roleId, groupId)` | KILLED | `replaceGroupRolesTouchesOnlyTheDifference` |
| G07 | negation dropped — deletes what IS desired | KILLED | 3 tests |
| G08 | negation dropped — inserts only what already exists | KILLED | 4 tests |
| G09 | `delete(...)` → `save(...)` (delete/save swap) | KILLED | `…TouchesOnlyTheDifference`, `…AcceptsAnEmptySet` |
| G10 | off-by-one — `break` after the first removal | KILLED | `replaceGroupRolesAcceptsAnEmptySet` |
| G11 | off-by-one — first desired id skipped on insert | KILLED | `…DeduplicatesTheRequest`, `failingSaveRollsBack…` |
| G12 | dedup removed (`LinkedHashSet` → `ArrayList`) | KILLED | `replaceGroupRolesDeduplicatesTheRequest` |
| X09 | wrong group read (`findByGrouplistId(0L)`) | KILLED | 3 tests |
| X01 / **X01b** | **stray bulk clear before the set difference** | **SURVIVED** | — **H-1** |

### `UserGroupService.deleteGroup`

| id | mutant | verdict | killed by |
|---|---|---|---|
| D01 | `existsById` guard removed | KILLED | `deleteGroupRefusesAnUnknownId` |
| D02 | `existsById` guard moved after the three deletes | KILLED | `deleteGroupRefusesAnUnknownId` |
| D03 | **group entity deleted FIRST** (real 23503 on every delete) | **SURVIVED @51d8c09** | — |
| D03b / **D03d** | same mutant, re-run after the author's `InOrder` fix | **KILLED** | `deleteGroupClearsBothJoinTables` |
| D03c | the two join-table clears swapped with each other | KILLED | `deleteGroupClearsBothJoinTables` |
| D04 | role join-table clear dropped | KILLED | `deleteGroupClearsBothJoinTables` |
| D05 | member join-table clear dropped | KILLED | `deleteGroupClearsBothJoinTables` |
| D06 | `deleteGroupById` → `deleteById` (SBDEV-3011 hazard) | KILLED | `deleteGroupNeverMaterialisesTheEntity` + 2 |
| D07 | bare `@Transactional` | KILLED | 3 tests |
| D08 | `NOT_SUPPORTED + readOnly` | KILLED | `deleteGroupTransactionDefinitionIsAWritableRequiredTransaction` |
| D09 | throws when `groupsRemoved == 0` | KILLED | `deleteGroupToleratesAConcurrentDelete` |
| X04 | role-table clear called twice | KILLED | `deleteGroupClearsBothJoinTables` |
| X10 | wrong id to the member-table clear (`0L`) | KILLED | `deleteGroupClearsBothJoinTables` |

### `UserService.replaceUserGroups`

| id | mutant | verdict | killed by |
|---|---|---|---|
| U01 | bare `@Transactional` | KILLED | 3 tests |
| U02 | `NOT_SUPPORTED + readOnly` | KILLED | `replaceUserGroupsTransactionDefinitionIsAWritableRequiredTransaction` |
| U03 | `rollbackFor` removed | **SURVIVED** | — (L-6) |
| U04 | composite key swapped: `UserGroupUserId(userId, groupId)` | KILLED | `replaceUserGroupsBuildsTheCompositeKeyInDeclaredOrder`, `…TouchesOnlyTheDifference` |
| U05 | `existing` keyed on `userlistId` instead of `grouplistId` | KILLED | 2 tests |
| U06 | set difference → delete-all-then-reinsert-all | KILLED | 2 tests |
| U07 | wrong finder axis `findByUserlistId` → `findByGrouplistId` | KILLED | 2 tests |
| U08 | negation dropped on the delete branch | KILLED | 2 tests |
| U09 | negation dropped on the insert branch | KILLED | 5 tests |
| U10 | dedup removed | KILLED | `replaceUserGroupsDeduplicatesTheRequest` |
| X03 / **X03b** | **stray bulk clear before the set difference** | **SURVIVED** | — **H-1** |

### `UserService.deleteUser`

| id | mutant | verdict | killed by |
|---|---|---|---|
| V01 | bare `@Transactional` | KILLED | 3 tests |
| V02 | `NOT_SUPPORTED + readOnly` | KILLED | `deleteUserTransactionDefinitionIsAWritableRequiredTransaction` |
| V03 | `existsById` guard removed | KILLED | `deleteUserRefusesAnUnknownId` |
| V04 | **order swapped** — user row deleted before memberships | KILLED | `deleteUserClearsMembershipsFirst` (`InOrder`) |
| V05 | membership clear dropped | KILLED | `deleteUserClearsMembershipsFirst`, `…DoesNotCascade…` |
| V06 | `deleteUserById` → `deleteById` | KILLED | `deleteUserNeverMaterialisesTheEntity` + 2 |
| V07 | wrong axis `deleteByUserId` → `deleteByGroupId` | KILLED | 2 tests |
| V08 | throws when `usersRemoved == 0` | KILLED | `deleteUserToleratesAConcurrentDelete` |
| X02 | `deleteByUserId` called twice | KILLED | 2 tests |
| X08 / **X08b** | **unrelated cascade added (`printerRepository.deleteById`)** | **SURVIVED** | — **M-1** |

### Repository query contracts (all five bulk deletes)

| id | mutant | verdict | killed by |
|---|---|---|---|
| Q01 | JPQL: role clear filters `rolelistId` not `grouplistId` | SURVIVED @51d8c09 → **KILLED** @0a3589f | `roleJoinTableFiltersOnTheGroupColumn` |
| Q02 | JPQL: user-axis clear filters `grouplistId` not `userlistId` | **KILLED** | `membershipTableUserScopedClearFiltersOnTheUserColumn` |
| Q03 | JPQL: group-axis clear filters `userlistId` not `grouplistId` | **KILLED** | `membershipTableGroupScopedClearFiltersOnTheGroupColumn` |
| Q04 | `@Modifying` removed | KILLED | `allFiveHonourTheContract` |
| Q05 | `clearAutomatically = true` added | KILLED | `allFiveHonourTheContract` |
| Q06 | bare `@Transactional` added to a repository method | KILLED | `allFiveHonourTheContract`, `deleteGroupRollsBackWhenTheEntityDeleteFails` |
| Q07 | `@RestResource(exported = true)` | KILLED | `allFiveHonourTheContract` |
| Q08 | `deleteGroupById` filters `clientId` not `id` | KILLED | `groupEntityDelete` |
| Q09 | `deleteUserById` filters `clientId` not `id` | KILLED | `userEntityDelete` |
| Q10 / **Q10b** | `flushAutomatically` dropped | **SURVIVED** | — L-4 |

### `UserController`

| id | mutant | verdict | killed by |
|---|---|---|---|
| C01 / **C01c** | cap check removed | SURVIVED @51d8c09 → **KILLED** @0a3589f | `shouldRejectAnOversizedGroupList` |
| C02 / **C02c** | cap boundary `>` → `>=` | **SURVIVED** | — L-3 |
| C03 | cap constant 500 → 1 | KILLED (incidentally) | `shouldSaveUserGroupsSuccessfully` |
| C04 | cap constant 500 → `Integer.MAX_VALUE` | SURVIVED @51d8c09 (subsumed by C01c) | — |
| C05 | `existsById(userId)` guard removed | KILLED | `shouldRejectAnUnknownUserId` + 2 |
| C06 | `requiredId` widens via `intValue()` | KILLED | `shouldAcceptLongIds` |
| C07 / **C07c** | `requiredId` `Number` guard removed | **SURVIVED** | — **M-2** |
| C08 | `groups` non-array check removed | KILLED | `shouldRejectANonArrayGroups` |
| C09 | group id order reversed before delegating | KILLED | `shouldSaveUserGroupsSuccessfully` |
| C10 | `delet()` swallows the exception and returns 200 (old contract) | KILLED | `shouldNotReportSuccessWhenTheDeleteFails` |
| C11 | `delet()` gate moved after the service call | KILLED | `deleteIsGated` |
| C12 / **C12b** | `saveUserGroups()` gate moved after validation + service call | KILLED | `shouldDenyWithoutTheUserManagementFunction`, `shouldDenyAnonymous…` |
| C13 / **C13b** | catch widened to `DataAccessException` | **SURVIVED** | — **M-4** |
| C14 / **C14b** | success body no longer contains `DELETED` | **SURVIVED** | — L-1 |
| C15 | one-arg exception reverted to the two-arg field form | **SURVIVED** | — L-2 |
| C16 | empty `groups` array rejected | **SURVIVED** | — L-5 |
| Y01 | child-id check inverted (only KNOWN ids rejected) | KILLED | `shouldRejectAnUnknownGroupIdInTheArray` + 2 |
| Y02 | `distinct()` dropped | **SURVIVED** | — L-7 (behaviour-equivalent) |
| Y03 | child-id lookup handed an empty list | **SURVIVED** | — **M-3** |
| Y04 | child-id check removed entirely | KILLED | `shouldRejectAnUnknownGroupIdInTheArray` + 2 |
| Y05 | child-id check moved after the service call | KILLED | `shouldRejectAnUnknownGroupIdInTheArray` |

### `UserGroupController`

| id | mutant | verdict | killed by |
|---|---|---|---|
| K01 / **K01c** | cap check removed | SURVIVED @51d8c09 → **KILLED** @0a3589f | `rejectsAnOversizedRoleList` |
| K02 / **K02c** | cap boundary `>` → `>=` | **SURVIVED** | — L-3 |
| K03 | cap constant 500 → `Integer.MAX_VALUE` | SURVIVED @51d8c09 (subsumed by K01c) | — |
| K04 | `existsById(groupId)` guard removed | KILLED | `rejectsAnUnknownGroupId` + 3 |
| K05 | `requiredId` widens via `intValue()` | KILLED | `acceptsLongIds` |
| K06 | `roles` non-array check removed | KILLED | `rejectsANonArrayRoles` |
| K07 | role id order reversed before delegating | KILLED | `replacesGroupRoles` |
| K08 | `delete()` service call dropped, still returns 200 `DELETED` | KILLED | `deletesGroupAndRelations`, `unknownGroupPropagatesNotFound` |
| K09 | `saveGroupRoles()` service call dropped, still returns `true` | KILLED | 3 tests |
| K10 | returns `FALSE` instead of `TRUE` | KILLED | 2 tests |
| X05 | controller regrows a direct repository write | KILLED | `deletesGroupAndRelations` |

**Score against `0a3589f`: 91 killed / 13 open survivors** (of which 6 are Low and 2 informational).

---

## RULED OUT — checked, found adequate

* **Every `@Transactional` attribute on all four methods.** Manager name (bare-`@Transactional`
  mutants `G01`/`D07`/`U01`/`V01` all die on the `@Primary` landlord mock), propagation and `readOnly`
  (`G02`/`D08`/`U02`/`V02` all die on the captured `TransactionDefinition`). The `@Primary` landlord
  mock plus the argument captor is the right shape and it demonstrably works — this is the pattern
  the repo learned from a `NOT_SUPPORTED + readOnly` mutant that once scored 100% green.
* **Every composite-key argument order.** `UserGroupUserId(groupId, userId)` and
  `UserGroupUserRoleId(groupId, roleId)` swaps both die (`U04`, `G06`). Also verified the records carry
  explicit `@Column(name=…)` on each component, so record order ↔ DB column is pinned in the mapping,
  not by convention.
* **Every set-difference branch**: both negations, both loops, delete/save swap, two off-by-ones,
  dedup, map key, finder axis, id plumbing — 15 mutants, all killed on both services.
* **Every `existsById` guard**, including guard-moved-after-writes variants (`D01`, `D02`, `V03`,
  `C05`, `K04`).
* **Bulk-delete presence and ordering** — after the author's `InOrder` fix, both services.
* **Concurrent-delete tolerance** (`deleteGroupById`/`deleteUserById` returning 0) — `D09`, `V08`.
* **The `deleteById` / `findById` absence assertions** — `D06` and `V06` both die, so the SBDEV-3011
  `CollectionRemoveAction` guard is real, not decorative.
* **Both controllers' delegation and no-direct-write-path assertions** — `K08`, `K09`, `X05`.
* **The HTTP contract change that is the point of the ticket** — `C10` (restore the old
  200-with-errors body) dies on `shouldNotReportSuccessWhenTheDeleteFails`.
* **Both authorization gates' ordering** — `C11`, `C12b`. (Whether the gates are *sufficient* is the
  authz lane's call, not mine. I note only that `UserGroupController.delete` and `saveGroupRoles`
  carry no `@RequiresFunction` at all and no test asserts one — flagged for that lane, not scored
  here.)
* **`UserGroupQueryContractUnitTest` is not vacuous** — 7 mutants kill it; the `method()` helper
  fails loudly on a missing method; keyed on name + arity.
* **Test isolation and order independence** — alone, together, and 3 random-order seeds.
* **No new suite regressions** — 5415 run, only the 2 documented pre-existing failures.
* **Precedent parity with `UserRoleServiceTransactionBoundaryTest`** (SBDEV-3005/3011, merged): the
  new classes are a strict superset — 15 and 13 tests against the precedent's 6, and they add
  minimality, dedup, key-order, cascade-completeness and concurrent-delete cases the precedent has
  none of.

---

## Recommended action before merge

Required (the two that protect against a plausible next edit):

1. **H-1** — 4 one-line `never()` verifies (2 per service test class).
2. **M-2** — 2 tests copied from `UserRoleControllerUnitTest:281-300`.

Should-fix (cheap, and each closes a stated-but-unenforced design claim):

3. **M-1** — broaden or rename `deleteUserDoesNotCascadeOperationalHistory`.
4. **M-3** — pin the `findAllById` argument on both controllers.
5. **M-4** — one test that a non-`DataIntegrityViolationException` `DataAccessException` propagates.

Optional: L-1 … L-5. L-6 and L-7 need no action.

Not blocking, but must not be skipped at merge: the **manual** checks in "What nothing can catch",
items 2 and 3 — a boot against a tenant (which is what validates the five JPQL strings), and one real
`GET /v3/user/delete/{id}` against a user with picking history on hydra-uat with a membership row
count either side. Those two are the only evidence that the ticket's actual defect is fixed. Note item
6: the group-delete endpoint cannot be reached from the web UI, so that half must be exercised by
direct API call.
