---
title: SBDEV-3012 review — authorization regressions and exposed write surface
ticket: SBDEV-3012
pr: wms2-api #182
reviewed_commit: 51d8c09
lane: authz / exposed write surface
reviewer: authz-lane
date: 2026-08-21
verdict: SHIP WITH FIXES
---

# SBDEV-3012 (PR #182) — authz lane review

**Scope of this lane:** authorization regressions and newly exposed write surface. Transaction
semantics, Hibernate `ActionQueue` reasoning and test style are other lanes' — I only touch them
where they change an authz conclusion.

**Reviewed against commit `51d8c09`** (`bugfix/SBDEV-3012-user-group-atomicity`), diffed against
`origin/develop`. See §Process note — the shared worktree had uncommitted edits from other lanes
during the review, so all mutation testing was done in an isolated copy restored from
`HEAD`.

## Verdict: SHIP WITH FIXES

The four touched handlers' gates are intact, correctly ordered, and — for the assertions that
matter — **provably non-vacuous**. I applied my own mutants and they are killed. One required fix
(F1, Medium) and one decision to record explicitly (F2, Medium).

---

## Findings

### F1 — Medium. The five new bulk-delete methods have NO regression pin on `exported = false`

**File:** `src/main/java/net/aim_ai/wms/repo/jpa/UserGroupUserRoleRepository.java:55`,
`UserGroupUserRepository.java:44` and `:60`, `UserGroupRepository.java:78`,
`UserRepository.java:83`

The annotation is correct on all five and it genuinely works (see RULED OUT #7). What is missing is
the test that keeps it correct.

**Measured surviving mutant.** I flipped all five to `@RestResource(exported = true)` and ran the
entire unit suite in an isolated copy:

```
M5 patched, exported=true occurrences: 5
[ERROR]   OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses:43      <- pre-existing
[ERROR]   MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate:468  <- pre-existing
[ERROR] Tests run: 5372, Failures: 2, Errors: 0, Skipped: 61
```

Two failures, both on the known `develop` baseline. **The mutant survives 5372 tests.** Nothing in
this PR, and nothing anywhere in the suite, notices that five ungated bulk-DELETE routes just
appeared under `/v3`.

**Why that matters concretely.** With `exported = true` (which is also what you get by simply
*deleting* the annotation, since `RepositoryRestConfiguration.exposeRepositoryMethodsByDefault`
defaults to `true` and `RestConfiguration` never changes it), Spring Data REST publishes each as a
search resource. A `GET /v3/userGroupUser/search/deleteByGroupId?groupId=N` then executes
`DELETE FROM UserGroupUser u WHERE u.id.grouplistId = :groupId` — a bulk delete on
`mywms_group_mywms_user`, the table `AccessService.doesUserHaveAccess` traverses via
`UserRepository.getAllRoles`. `FunctionGuardInterceptor` structurally cannot reach it: SDR's
`RepositoryRestHandlerMapping` does not consult `WebMvcConfigurer#addInterceptors`
(`WebConfig.java:30-31`, `RequiresFunction.java:38-40`, SBDEV-2968 §3.1-A9). So neither the class-level
`@RequiresFunction` nor `denyUnlessUserManagementAllowed()` applies — that is exactly the
class of hole SBDEV-3013/3017 exist for.

**The precedent already built this pin and this PR did not follow it.** SBDEV-3011 added *two* bulk
deletes and wrote `UserRoleQueryContractUnitTest$HalSurfaceContract.everyNewMethodIsUnexported`
(`src/test/java/net/aim_ai/wms/unit/repo/UserRoleQueryContractUnitTest.java:285-311`) whose own
assertion message says omitting the annotation "publishes a new ungated write/search surface under
/v3, which is the class of problem SBDEV-3013 exists for." This PR adds *five* and pins none. Grep
confirms no test in the repo names any of the five new methods except the two transaction-boundary
tests, and neither mentions `exported` or `RestResource`.

**Fix.** Add the five methods to that existing test's list (or a sibling nested class in a
`UserGroupQueryContractUnitTest`), asserting both that `@RestResource` is present — deleting the
annotation outright silently falls back to exported — and that `exported()` is `false`. It is
reflection-only, needs no context, and is ~20 lines. Re-run my M5 mutant afterwards to confirm it
now goes red.

### F2 — Medium (pre-existing; a decision to record, not a regression). The parallel SDR route into these same tables is still open

Not introduced by this PR. Raising it because this lane's question is "exposed write surface on
these tables", and because SBDEV-3011 — same defect family, immediately prior ticket — closed
exactly this for `userRole` and this PR does not close it for `user` / `userGroup`.

Verified from the framework source at the exact version in use
(`spring-data-rest-core-4.5.7`, `CrudMethodsSupportedHttpMethods.java:176-181`): the item `DELETE`
verb is derived from `CrudMethods.getDeleteMethod()` and is exported unless a
`@RestResource(exported = false)` override says otherwise.

| Repository | Supertype | Consequence |
|---|---|---|
| `UserRepository` | `CrudRepository<User, Long>` | `DELETE /v3/user/{id}` exported |
| `UserGroupRepository` | `CrudRepository<UserGroup, Long>` | `DELETE /v3/userGroup/{id}` exported |
| `UserGroupUserRepository` | `PagingAndSortingRepository` + `CrudRepository` | item `DELETE` + collection write on `mywms_group_mywms_user` |
| `UserGroupUserRoleRepository` | `PagingAndSortingRepository` + `CrudRepository` | item `DELETE` + collection write on `mywms_group_mywms_role` |
| `UserRoleRepository` | **`NoDeletePagingAndSortingRepository`** | closed by SBDEV-3011 |

`RestConfiguration.java:34-45` additionally `exposeIdsFor(... UserGroupUser.class,
UserGroupUserRole.class ...)`, so the composite ids of both join tables are serialized.

None of these routes carry a function gate, and none can — the interceptor never sees them. So this
PR hardens the controller path for group/user deletion and membership replacement while an
un-gated route to the same two tables remains published.

**I did NOT confirm exploitability and am not claiming it.** There is no live instance available to
me and the v2 IT lane cannot boot (SBDEV-2217), so this is configuration-level only. Per the
standing rule that an advertised capability is not an exploitable one, the write must be tested
before anyone calls it an exposure. The one corroborating *measurement* is from SBDEV-2984:
`PATCH /v3/user/{id}` was measured returning 200, so the SDR item resource on `/v3/user` is at
least live and writable.

**Recommendation.** Do not expand this PR's scope on my say-so. Either (a) add
`@RestResource(exported = false) @Override void deleteById(Long); void delete(User);` to
`UserRepository` / `UserGroupRepository` in this PR — cheap, same files already touched, but it
needs a sweep of both UIs and oms-laravel-api first to confirm nobody calls those routes — or
(b) attach this evidence to the **existing SBDEV-3017** ("the general SDR gap", already referenced
from `FixLocationAssignmentRepository.java:34` and `RequiresFunction.java:40`). Prefer (b): it is
the same code-path visit as SBDEV-3017 and files no new ticket.

### F3 — Low. Two of the retargeted gate assertions are still decorative; the kill comes from the wrong assertion

**File:** `src/test/java/net/aim_ai/wms/unit/controller/UserControllerUnitTest.java:511-525` and
`:542-546`

The author's claim that the load-bearing assertions were correctly retargeted onto the service
mocks is **confirmed** (see RULED OUT #2 for the mutants that prove it). But the *other* assertions
he kept in the same tests are not doing work, and the mutant that looks like it proves they are is
being killed by something else.

Mutant: guard moved to after the service call, `existsById` check left where it is. It dies —
but on the exception-type assertion, not on any `never()` verify:

```
[ERROR] UserControllerUnitTest$SaveUserGroups.shouldDenyWithoutTheUserManagementFunction:511
Expecting actual throwable to be an instance of: AccessDeniedException
but was: ApiInvalidParameterException: Unknown userId 1
  at UserController.saveUserGroups(UserController.java:415)
```

Because the gate tests never stub `userRepository.existsById(1L)`, Mockito returns `false` and the
method throws `ApiInvalidParameterException` before reaching the write. So
`verify(userRepository, never()).existsById(anyLong())` (added by this PR) and the three retained
`verify(userGroupUserRepository, never())...` lines can never be the failing assertion in these
tests. The comment on the block says the repository verifies are "kept only as a check that the
controller has not regrown a direct write path" — that is honest about them being weak, but the new
`existsById` one is presented as the existence-oracle guarantee and is not.

**Fix (optional).** Stub `when(userRepository.existsById(anyLong())).thenReturn(true)` in the two
gate tests. Then a guard moved past the existence check fails on
`verify(userRepository, never()).existsById(...)` — the assertion whose name says what went wrong —
rather than on a confusing wrong-exception-type message.

### F4 — Low. The new size caps have no test

`UserController.MAX_GROUPS_PER_REQUEST` (`:66`) and
`UserGroupController.MAX_ROLES_PER_REQUEST` (`:53`) are never exercised. Enumerating both
controllers' test classes shows no case sends more than 3 ids. Not an authz concern — the cap is
bounded-work hygiene, and the gate runs before it either way — but a mutant deleting either
check would survive. One-line-each tests if you want them pinned.

---

## Found nothing

Stated explicitly, as required:

- **Point 1 (gates present, first, before every write): found nothing wrong.** No gate that existed
  on `develop` is weakened, removed, moved, or reordered on any of the four touched handlers.
- **Point 5 (existence oracle): found nothing wrong.** On both new validation paths the gate
  precedes the existence check. An unauthorized caller gets `AccessDeniedException` and never
  learns whether the id exists.
- **Point 6 (SBDEV-3013 escalation chain): found nothing.** Nothing in this diff makes
  create-role → grant-function → attach-to-own-group easier, and nothing widens what a `wms_user`
  can reach. The one input-surface widening (`requiredId` accepting any `Number`) is paired with a
  new `existsById` rejection that makes the endpoint strictly *narrower* than before: an unknown
  `groupId` / `userId` was previously either a 500 or, with an empty list, a silent 200.
- **Point 3 (removed constructor dependencies): found nothing.** No gate, test, or assertion
  depended on them.

---

## RULED OUT (checked, found correct)

1. **All four handlers still gated, guard first.** `UserController.delet:360` and
   `saveUserGroups:398` each call `denyUnlessUserManagementAllowed()` as the first statement,
   outside every `try`, before any repository or service call. `UserGroupController.delete:107` and
   `saveGroupRoles:131` are covered by the class-level `@RequiresFunction`
   (`UserGroupController.java:43`) plus `FunctionGuardInterceptor.GUARDED` membership
   (`FunctionGuardInterceptor.java:96`), which runs in `preHandle` — i.e. before the method body,
   before the new `requiredId`/size-cap/`existsById` code. Counts are identical to `develop`:
   `denyUnlessUserManagementAllowed()` 9 → 9, `@RequiresFunction` 11 → 11.
2. **The retargeted service-level assertions are NON-VACUOUS — verified with my own mutants, not
   the author's.** Baseline first: 112/112 green across the seven relevant test classes in a clean
   isolated copy.
   - **M1** — delete the guard from `saveUserGroups`: killed, 2 failures.
   - **M2b** — write moved *before* the guard (`userService.replaceUserGroups(...)` first, guard
     second, `existsById` third): killed, 3 failures, and the failing assertion is exactly the
     retargeted one, naming the violation precisely:
     ```
     userService.replaceUserGroups(<any long>, <any>);
     Never wanted here: -> at UserService.replaceUserGroups(UserService.java:216)
     But invoked here:  -> at UserController.saveUserGroups(UserController.java:413)
                           with arguments: [1, [10, 20, 30]]
     ```
   - **M3** — `delet`'s guard moved inside the `try`, after `userService.deleteUser(userId)`:
     killed by `UngatedWriteEndpoints.deleteIsGated:731`, again on
     `verify(userService, never()).deleteUser(...)`.
   - **M6** — `existsById` hoisted above the guard: killed, 2 failures (though see F3 for *which*
     assertion does the killing).
   That is the property the ticket needed: a guard that runs after the destructive call fails the
   build.
3. **`UserGroupController`'s SBDEV-3013 gate is still pinned.** **M4** — remove the class-level
   `@RequiresFunction`: killed by `FunctionGuardArchTest.everyGuardedControllerCarriesRequiresFunction:227`
   and `controllerToFunctionMapMatchesTheGoldenMap:245`. Both the annotation and `GUARDED`
   membership survive the refactor.
4. **`UserControllerUnitTest.everyWriteHandlerIsGated:754` still covers both touched handlers.** It
   keys on the `@RequiresFunction` annotation via `getDeclaredMethods()`, not on method bodies or
   signatures, so the refactor and the new `throws ApiInvalidParameterException` clauses do not
   blunt it. `OPEN_BY_DESIGN` is unchanged (`isWmsUser`, `getAllRoles`).
5. **Removing the three injected repositories is security-neutral.** `mvn -o compile` clean;
   full unit suite `Tests run: 5372, Failures: 2` — the two known pre-existing `develop` failures
   (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`) and nothing else.
   `UserGroupUserRepository` / `UserGroupUserRoleRepository` remain injected where the writes now
   live (`UserGroupService`, `UserService`). Keeping the now-unreachable mocks as test fields is
   harmless.
6. **`UserController` still cannot join `GUARDED`, and this PR does not change that.** The two
   handlers that block it — `GET /isWmsUser/{username}` and `GET /getAllRoles/{username}`, both
   UI-bootstrap reads with no `@RequiresFunction` value meaning "public" — are untouched. No
   improvement is available to take here.
7. **`@RestResource(exported = false)` does prevent SDR from exposing the new methods — proven from
   framework source at the pinned version, not inferred from the annotation.**
   `spring-data-rest-core-4.5.7`:
   - `RepositoryResourceMappings.java:110-115` — iterates `repositoryInformation.getQueryMethods()`
     (which includes `@Modifying` methods; there is no filter for them) and adds each to
     `SearchResourceMappings` only `if (methodMapping.isExported())`.
   - `RepositoryMethodResourceMapping.java:76` —
     `this.isExported = annotation != null ? annotation.exported() : exposeMethodsByDefault;`
   - `RepositoryRestConfiguration.java:69` — `exposeRepositoryMethodsByDefault = true`, and
     `RestConfiguration` never overrides it.
   So `exported = false` removes the mapping entirely — no `/v3/<path>/search/<rel>` route is
   registered. Conversely, an unannotated `@Modifying` delete WOULD be published as a GET-invocable
   bulk delete, which is what makes F1 worth fixing.
   `RepositoryDetectionStrategies.ANNOTATED` (`RestConfiguration.java:47`) selects *repositories*,
   not methods, and all four of these repositories are annotated — so it provides no protection
   here.
8. **`deleteGroup`'s cascade is exhaustive.** The javadoc's `pg_constraint` claim holds; I
   re-queried `wms2-hydra-uat` independently. Exactly two foreign keys reference `mywms_group`:
   `mywms_group_mywms_role.grouplist_id` and `mywms_group_mywms_user.grouplist_id`. The three
   statements in `deleteGroup` are therefore complete, and deleting a group cannot leave a dangling
   grant that a later group reusing the id would inherit.
9. **No orphaned-grant privilege-inheritance hazard from `deleteUser` deliberately not clearing
   `mywms_user_mywms_role`.** I checked this specifically because `seqentities` can hand out ids
   inside gaps on migrated tenants, which would let a new user inherit a dead user's grants. It
   cannot happen: on `wms2-hydra-uat` that table carries
   `FOREIGN KEY (user_id) REFERENCES mywms_user(id)`, so `deleteUserById` on a user holding a direct
   role grant raises a constraint violation and the whole transaction rolls back — fails closed, no
   orphan. (Also moot in practice there: 0 of 19 users hold a direct role grant.)
10. **The claimed HTTP statuses are real.** `ApiInvalidParameterException` → **422** via
    `RestExceptionHandler.java:35`, and `EntityNotFoundException` → **404** via
    `RestExceptionHandler.java:153`. `RestExceptionHandler` is an *unscoped* `@ControllerAdvice`, so
    it does cover `net.aim_ai.wms.controller`. The javadoc's remark that
    `RestEndpointExceptionHandler` does not cover this package is true but immaterial — I flag it
    only because it reads as if nothing covers the package, which would have made the new 422/404
    contract a bare 500. It does not.
11. **The `DataIntegrityViolationException` catch in `delet:363` reaches the caller as intended.**
    `deleteUserById` is a bulk JPQL delete with `flushAutomatically = true`, so the FK violation
    raises during statement execution inside `deleteUser`, not at commit — it is therefore a
    `DataIntegrityViolationException` the controller can catch, not a `TransactionSystemException`
    escaping past it. Rollback still applies: `rollbackFor` *adds* rules to the default
    `RuntimeException || Error` rule, it does not replace it. (Transaction correctness beyond this
    is the tx lane's.)
12. **No information leak in the new 422 message.** It is only reachable by a caller who has already
    passed the gate.

---

## Could not verify

- **Live HTTP behaviour of any SDR route** (F2, and the counterfactual in F1). No running instance
  was available and the v2 Testcontainers IT lane cannot boot (SBDEV-2217), so both are
  configuration- and framework-source-level conclusions, not measured requests. The framework-source
  reading in RULED OUT #7 is decisive about *mapping registration*; it is not a measured 200/405.
- **Whether any client actually calls `DELETE /v3/user/{id}`, `DELETE /v3/userGroup/{id}` or the two
  join-table SDR resources.** I did not sweep `wms2-web-ui`, `wms2-mobile-ui`, `omsv2-UI` or
  `oms-laravel-api`. That sweep is a prerequisite for option (a) in F2.
- **Runtime behaviour of `deleteGroup` / `deleteUser` against a real database.** The Hibernate
  `ActionQueue` and `CollectionRemoveAction` reasoning in the new javadocs is unexecuted. It does
  not change any authz conclusion here, but nobody has run it — that is the tx lane's call.
- **Whether the destructive paths behave as documented on a real tenant.** Confirming a refusal
  requires attempting a delete, so, as on SBDEV-3011, the refusal branch stays behaviourally
  unconfirmed.

---

## Process note — shared-worktree collision

`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3012` is being edited by at least two
other lanes concurrently. My first `mvn test` run picked up a foreign mutant
(`UserGroupService.java:178`, `!existing.containsKey` → `existing.containsKey`) plus a stray
`break;` and a reordered delete, producing three `UserGroupServiceTransactionBoundaryTest` failures
that were not mine and not the PR's. I moved all mutation work to an isolated copy
(`$SCRATCH/authz-wt`) restored file-by-file from `git show HEAD:`, re-established a clean 112/112
baseline there, and re-ran everything. Every result quoted above is from that isolated copy. The
live worktree currently carries other lanes' uncommitted edits — including a reworked
`ApiInvalidParameterException` message in `delet` — so **this review is against `51d8c09`, not
against the current working tree.** Concurrent mutation testing in one worktree will keep producing
confident-looking false reds; each lane needs its own copy.
