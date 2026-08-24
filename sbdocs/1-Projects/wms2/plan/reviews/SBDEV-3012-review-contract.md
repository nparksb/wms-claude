---
ticket: SBDEV-3012
lane: HTTP contract changes and their consumers
pr: wms2-api #182
branch: bugfix/SBDEV-3012-user-group-atomicity
head: 51d8c09
base: origin/develop (dc56849)
reviewed: 2026-08-21
reviewer: contract-lane
status: review
---

# SBDEV-3012 — review lane: HTTP contract + consumers

**Scope of this lane:** the four endpoints' observable HTTP behaviour and every client of it.
Transaction internals, authorization enforcement and test style were left to the other three lanes
and are not assessed here except where they change a status code.

## Verdict: SHIP WITH FIXES

The direction is right and the headline claim holds: `GET /v3/user/delete/{userId}` really did answer
`HTTP 200 {"errors":[…]}` on failure, no consumer reads `.errors` on any of the four endpoints, and
`ApiInvalidParameterException` / `EntityNotFoundException` really do map to 422 / 404 for
`net.aim_ai.wms.controller` (verified below — this was the load-bearing question and the PR is right
about it).

Two fixes should land before merge (F1, F2). Both are small. Neither is a data-integrity risk; both
are "the new contract is honest about some failures and still bare-500 or misdescribed on others",
which is exactly the class of gap this ticket exists to close.

| # | Sev | One line |
|---|---|---|
| F1 | **Medium** | The 422's operator sentence is buried under a literal `"error":"Parameter error"`, and the web UI renders a *network* error for it and never refreshes the grid |
| F2 | **Medium** | An unknown id inside `groups[]` / `roles[]` is still a bare, bodyless 500 — the PR's own javadoc and its stated reference impl both promise 422 |
| F3 | Low | 422 vs 409 for "user has warehouse history": the repo's own decision guide prescribes 409 here |
| F4 | Low | `/v3/userGroup/delete/{groupId}` has **no reachable UI consumer** — the popup dispatches a Vuex namespace that does not exist. Pre-existing, but it means the group-delete half of this ticket cannot be manually verified through the UI |
| F5 | Low | `UserGroupController` is `@Tag(name = "RoleController")` — Swagger files the group endpoints under Role. Same copy-paste lineage as the two log strings the PR already fixed in this file |
| F6 | Low | No test pins any status code. Every `status()` assertion in both controller tests is `isOk()` |

---

## 1. Consumer inventory (complete)

Built by grepping `origin/develop` in every repo, **not** the local checkouts — `v2/wms2-web-ui` was
2 commits behind and `v2/wms2-mobile-ui` was 18 behind at review time (`git rev-list --left-right
--count HEAD...origin/develop` → `0 2` and `0 18`). Nothing in this inventory changes between the
local HEAD and `origin/develop`, but the check was necessary to say so.

### `POST /v3/user/saveUserGroups`

| Consumer | Reads the body? |
|---|---|
| `wms2-web-ui/store/admin/user.js:57-65` (`saveUserGroups`) | `console.log` only, then `$toast.success('User groups updated')`. No branch. |
| `wms2-web-ui/components/admin/userManagement/users/userGroupEdit.vue:82` | `await`s the dispatch, ignores the return, closes the dialog. |

### `POST /v3/userGroup/saveGroupRoles`

| Consumer | Reads the body? |
|---|---|
| `wms2-web-ui/store/admin/group.js:51-59` (`saveGroupRoles`) | `console.log` only, then `$toast.success('Group roles updated')`. No branch. |
| `wms2-web-ui/components/admin/userManagement/groups/groupRoleEdit.vue:81` | `await`s the dispatch, ignores the return, closes the dialog. |

### `GET /v3/user/delete/{userId}`

| Consumer | Reads the body? |
|---|---|
| `wms2-web-ui/store/admin/user.js:108-118` (`deleteUser`) | `console.log` only; then `dispatch('getUsers')` + `$toast.success('User deleted')` **inside the `try`**. `catch` → generic toast, **no `getUsers`**. See F1. |
| `wms2-web-ui/components/admin/userManagement/users/deleteUserPop.vue:46` | `await`s the dispatch (which never rejects — the store swallows), then `$emit('close')`. |

### `GET /v3/userGroup/delete/{groupId}`

| Consumer | Reads the body? |
|---|---|
| `wms2-web-ui/store/admin/group.js:87-97` (`deleteGroup`) | `console.log` only; `dispatch('getGroups')` + success toast in the `try`; `catch` → generic toast, no refresh. |
| `wms2-web-ui/components/admin/userManagement/groups/deleteGroupPop.vue:38` | **Dispatches `admin/userGroup/deleteGroup` — a namespace that does not exist.** See F4. The store action above is therefore unreachable. |

### Everything checked and found to hold NO consumer

- **`wms2-mobile-ui` — none, at all.** Its entire `store/` is 13 operational modules
  (`picking`, `putaway`, `palletizing`, …); there is no admin surface and no `pages/admin*`. Its only
  `/user/` traffic is `GET /user/getAllRoles/{username}` (`store/home.js:182,209`) and
  `GET /user/isWmsUser/{username}` (`store/index.js:76`), neither touched by this PR.
  `git grep -ln "userManagement|saveUserGroups|deleteUser"` over `origin/develop` returns nothing.
- **Cypress.** `wms2-web-ui/cypress/e2e/wms/admin/admin.cy.js` exercises none of the four. It says so
  itself, twice: line 672 — *"Store code exists for /user/delete, /userGroup/delete, /userRole/delete
  but the UI walk-through did not exercise them"* — and line 874 lists them under endpoints not
  covered. Every recorded assertion there is a GET or a `/create`. **No Cypress test can break.**
- `v2/omsv2-UI`, `v2/oms-laravel-api`, `v1/wms-mobile-ui` — no hit for `saveUserGroups` /
  `saveGroupRoles`.
- `v1/wms-web-ui` has its own `store/admin/{user,group}.js` and the same two Vue components, but they
  target the **v1** API (`v1/wms-api`), which this PR does not touch.
- No HAR, Postman, Insomnia or checked-in OpenAPI collection exists in `wms2-web-ui`.
- No `Vuex.registerModule` anywhere in `wms2-web-ui` — so the module list under `store/` is the whole
  namespace list, which is what makes F4 provable rather than probable.

**The author's inventory (two stores + two Vue components) is complete for the code that actually
reaches these endpoints.** It missed the two facts in F4 and the Cypress self-documentation, but it
missed no live caller.

## 2. Does the new behaviour break any consumer?

**No consumer breaks on the shape change, and the author's claim is independently confirmed.** Not one
of the four store actions branches on `result`, `result.errors`, `result.errors.length`, or any
property of the response. All four do `console.log(result)` and then a fixed toast.

`saveUserGroups` 200 `{"errors":[]}` → 200 `true` is therefore invisible: `console.log('saveUserGroups
returned', true)` instead of `console.log('saveUserGroups returned', {errors: []})`. It also makes it
consistent with `saveGroupRoles`, which already returned `true`.

Worth recording because it is the near miss: **two sibling actions in the same file DO branch on
`.errors`** — `store/admin/user.js:73-80` (`updateUser`) and `:87-100` (`saveUser`) both do
`if (result.errors) { this.$toast.error(result.errors[0].message) }`. They call `/user/update` and
`/user/create`, which this PR does not change. If a later ticket converts those two to real statuses
the same way, **those consumers will break** — the `catch` will fire and the `.errors` branch will go
dead, silently downgrading a specific server message to the generic toast. That is not this PR's
problem; it is the reason F1's fix should be written as a reusable shape rather than a one-off.

## 3. F1 — Medium: the 422 is honest but unreadable, and the UI calls it a network fault

Two defects that compound, one on each side of the wire.

**API side.** `UserController.java:371` uses the **two-argument** `ApiInvalidParameterException(message,
field)` overload. That builds an `ApiParameterErrorMessage`, whose superclass constructor hard-codes
`error` to the literal string `"Parameter error"` and files the real sentence in a list keyed by the
field name (`ApiParameterErrorMessage.java`, `super("Parameter error")` + `addParameterError`). The
carefully-worded operator message the PR wrote therefore ships like this:

```json
{ "error": "Parameter error",
  "parameterErrors": [ { "userId": "User 5 cannot be deleted because they are still referenced by warehouse records (orders, receipts, bills of lading or messages). Operational history is never removed." } ] }
```

The only top-level human-readable field says `"Parameter error"`. To render the actual reason a client
must walk `parameterErrors[0]` and take `Object.values(...)[0]` — i.e. it must know the field name to
find the message. For a **path variable** on a single-parameter endpoint the field name carries no
information, so this is pure cost. The one-argument overload produces `{"error": "<the sentence>"}`,
which any client renders directly.

Note this also means one endpoint now has three different body shapes: 422 `{error, parameterErrors}`,
404 RFC-9457 `ProblemDetail` `{title, detail, status, retryable}`, and (per F2) bare 500.

**Fix, API side** — `src/main/java/net/aim_ai/wms/controller/UserController.java:371`: drop the
`, "userId"` second argument. Same for `UserGroupController`/`UserController`'s `requiredId` **only if**
you also want those readable — there the field name is genuinely informative (`groups` vs `userId`), so
leave those as-is.

**UI side.** `store/admin/user.js:108-118` on `origin/develop`:

```js
async deleteUser(context, data) {
  try {
    const result = await this.$axios.$get(`/user/delete/${data.userId}`)
    console.log('deleteUser returned', result)
    context.dispatch('getUsers')
    this.$toast.success('User deleted')
  } catch (error) {
    console.log(error);
    this.$toast.error('Error: Request failed due to a network or server issue. Please retry.')
  }
},
```

Concrete user-visible failure, on the dominant path (the plan measured 15 of 19 hydra-uat users as
undeletable): an admin clicks Delete on a user with warehouse history → the confirm dialog closes →
a red toast reads *"Error: Request failed due to a network or server issue. Please retry."* → the row
is still in the grid, because `getUsers` is inside the `try` and never runs. The real reason exists
only in `console.log(error)`. The message names the wrong subsystem and prescribes an action
(retry) that is guaranteed to fail forever.

**Is that acceptable as an interim state?** It is a genuine improvement, not a regression — the old
behaviour on this exact input was a **green** *"User deleted"* toast while the user survived and their
group memberships had already been destroyed. Misleading-red beats lying-green. And the grid not
refreshing is accidentally consistent: the row is still there because the user is still there.

But it should not ship as-is, for one reason: the toast tells the operator to retry a thing that can
never succeed, and this PR is the change that puts that toast on the dominant path. Deferring wholly
to SBDEV-3030 means shipping a known-wrong instruction to operators in the meantime, for the sake of
about ten lines.

**Fix, UI side** (`wms2-web-ui/store/admin/user.js`, `deleteUser`):

```js
} catch (error) {
  console.log(error)
  const status = error?.response?.status
  const data = error?.response?.data || {}
  // 422/409 -> ApiErrorMessage {error}; 404 -> RFC 9457 ProblemDetail {detail}
  const reason = data.error || data.detail
  if (status === 422 || status === 409) {
    this.$toast.error(reason || 'This user cannot be deleted.')
  } else if (status === 404) {
    this.$toast.error('That user no longer exists.')
    context.dispatch('getUsers')          // the grid is stale — refresh it
  } else {
    this.$toast.error('Error: Request failed due to a network or server issue. Please retry.')
  }
}
```

`data.error` only carries the sentence if the API-side fix above lands; otherwise the fallback string
is what renders. The two halves are worth doing together.

No automatic-retry hazard, checked: `wms2-web-ui/plugins/axios.js:53-54` gates `axiosRetry`'s
`retryCondition` on `status !== 401 && status !== 403 → return false`, so a 422 or 404 is never
retried and never reaches `onMaxRetryTimesExceeded`'s forced logout. There is no global `onError`
handling either — `plugins/axios.js:200-207` just re-rejects. So the only surface is the store's
`catch`.

## 4. F2 — Medium: an unknown child id is still a bare, bodyless 500

`UserController.java:415` and `UserGroupController.java:152` validate the **parent** id with
`existsById` and 422 on miss. Neither validates the **children** in `groups[]` / `roles[]`.

An unknown child id reaches `userGroupUserRepository.save(new UserGroupUser(...))` (or the role
equivalent), the FK violation surfaces at flush/commit as `DataIntegrityViolationException`, and
nothing handles it: `RestExceptionHandler` has no `DataIntegrityViolationException` handler and no
`Exception` catch-all, and the only `@ExceptionHandler(Exception.class)` in the codebase is
`RestEndpointExceptionHandler.java:84`, which is `@ControllerAdvice(basePackages =
"net.aim_ai.wms.controller.rest")` — a different package. Result: bare 500, no body, and the same
generic network toast from F1.

Three reasons this is worth fixing in this PR rather than deferring:

1. **The PR's own javadoc promises otherwise.** `UserGroupController.java:149-151`: *"Without this
   check an unknown groupId produced an FK violation (a 500)"* — the sentence is about the parent, but
   the surrounding claim in the ticket is "unknown id → 422", unqualified.
2. **The stated reference implementation already does it.** `UserRoleController.saveRoleFunctions`
   (on `develop`, from SBDEV-3005) validates both, at lines 159-168:
   `findAllById(distinctFunctionIds)` → collect known → `throw new ApiInvalidParameterException("Unknown
   functionId(s): " + unknownFunctionIds, "functions")`. Both new endpoints copy that method's
   `requiredId`, its `MAX_*_PER_REQUEST` bound and its `existsById` parent check, and stop one block
   short. The asymmetry between three near-identical endpoints is itself a maintenance hazard.
3. **It is reachable without a hostile client.** Two admins on the same screen, or one admin with a
   stale dialog: the group/role list is fetched when the dialog opens, so a group deleted in another
   tab in between submits an id that no longer exists. `groupRoleEdit.vue:65-72` makes this likelier —
   its `groupRoles` watcher has no `else` branch, so `itemsInEdit` keeps the previous group's role ids
   when the next group has none, and those stale ids get submitted verbatim. (That carryover is
   pre-existing and is a bug in its own right; it is out of this lane, but it is the mechanism that
   turns F2 from theoretical into reachable.)

**Fix:** mirror `UserRoleController.java:159-168` in both new endpoints, using
`userGroupRepository.findAllById(...)` and `userRoleRepository.findAllById(...)` respectively.

Same shape, lower severity, for the record: the `existsById` parent check runs in the controller,
**outside** the service's transaction, so a parent deleted between the check and the write is also a
bare 500. That TOCTOU is inherited from the reference impl and is not worth widening this PR for.

## 5. F3 — Low: 422 vs 409 for "this user has warehouse history"

**409 is the better code, and the argument is the repo's own, not mine.**
`sbdocs/3-Resources/architecture/wms-exception-taxonomy.md` §6 (line ~354) is an explicit decision
tree, and it routes this exact case:

```
Is the error a database uniqueness / FK constraint violation?
  └─ Yes → ApiConstraintViolationException
```

`ApiConstraintViolationException` maps to `HttpStatus.CONFLICT` (`RestExceptionHandler.java:26,49`).
The condition being reported is literally an FK constraint violation on the nine `operator_id` FKs —
the PR's own comment at `UserController.java:361-364` says so. RFC semantics agree: 409 is "conflicts
with the current state of the target resource", which is what operational history is; 422 is
"unprocessable content", which frames a well-formed id pointing at a real user as bad input. The 422
body reinforces the wrong frame by keying the message under `"userId"` (F1).

**The honest counter-argument**, because it is not free: 409 is already this API's *retryable* status —
`ObjectOptimisticLockingFailureException` and `PessimisticLockingFailureException` both map to 409 with
`retryable: true` in a `ProblemDetail` (`RestExceptionHandler.java:166-182`). A client keying on status
alone cannot tell those from a permanent refusal, and `ApiConstraintViolationException` returns a bare
`ApiErrorMessage` with no `retryable` property to discriminate on. Given F1's fix will make the UI
branch on status, that collision is real.

**Recommendation:** switch to 409. The `retryable` property on the lock responses is the discriminator,
and matching the documented decision tree is worth more than avoiding a shared status —
`ApiConstraintViolationException(message)` also gives the readable `{"error": "<sentence>"}` body F1
wants, so the two fixes collapse into one. Note the exception has **no** field-name overload, which is
fine here.

**If 422 stays**, add one line to `wms-exception-taxonomy.md` §6 recording the deliberate deviation and
why. Otherwise the next person to read that decision tree will "fix" this to 409 as a drive-by, and
they will be following the documentation.

Not a blocker either way: no consumer branches on status today.

## 6. F4 — Low: `/v3/userGroup/delete/{groupId}` has no reachable consumer

`components/admin/userManagement/groups/deleteGroupPop.vue:38`:

```js
await this.$store.dispatch('admin/userGroup/deleteGroup', {groupId: this.itemToDelete.id})
```

There is no `store/admin/userGroup.js`. The module is `store/admin/group.js` → namespace
`admin/group`, and the action lives at `store/admin/group.js:87`. Evidence it is the only such
dispatch: `git grep -n "admin/(userGroup|group)/"` over `origin/develop` returns 11 hits, and this is
the sole `admin/userGroup/` one — `updateGroup`, `saveGroup`, `checkName`, `getGroupRoles`,
`getGroupDetail`, `getGroups`, `saveGroupRoles` all correctly use `admin/group/`. No `registerModule`
call exists anywhere in the repo, so no dynamic module can be supplying that namespace.

Vuex logs `[vuex] unknown action type: admin/userGroup/deleteGroup` and returns `undefined` without
throwing, so `await` resolves, `$emit('close')` runs, and `group.vue:243 closeDeletePop` just clears
the flag. **Delete Group is inert today:** no HTTP request, no toast, no error the operator can see,
group still listed.

Consequences for this PR, both benign but both worth stating:

- The `200 / bare-500 → 200 / 404` change on that endpoint is currently **unobservable** from the UI.
  It cannot regress anything.
- The group-delete cascade this PR made atomic (`UserGroupService.deleteGroup`) **has never run from
  the UI**, so any manual-QA step in this ticket that says "delete a group and confirm both join
  tables cleared" cannot be executed until the dispatch is fixed. Fix the typo first, or verify that
  half by direct HTTP call and say so on the ticket.

Pre-existing, not introduced here, and a one-word fix (`admin/userGroup/` → `admin/group/`) in a repo
this PR does not touch. Out of scope to fix here; in scope to know about before signing off manual
verification.

## 7. F5 — Low: Swagger tag and the copy-paste lineage

`UserGroupController.java:25` is `@Tag(name = "RoleController")`, so SpringDoc files every group
endpoint under the Role tag. This is the same PrinterController/RoleController copy-paste lineage as
the two log strings the PR *did* fix in this file (`"delete printer with Id"` → `"delete group with
Id"`, `"Role with Id … is deleted"` → `"Group with Id …"`). Fixing the third is one word in a file the
PR already edits.

Otherwise **there is no OpenAPI drift**: neither controller carries a single `@Operation`,
`@ApiResponse`, `@Parameter` or `@Schema` annotation (grepped both files post-change), so the generated
spec has no hand-written status list to go stale. The new 422/404 responses simply will not appear in
Swagger — accurate-by-omission rather than wrong.

## 8. F6 — Low: nothing pins the status codes

Every `status()` assertion in `UserControllerUnitTest` and `UserGroupControllerUnitTest` is
`isOk()` — 21 of them, and not one `isUnprocessableEntity()` or `isNotFound()`. The new behaviour is
asserted by direct invocation instead:
`UserControllerUnitTest.java:401` `.isInstanceOf(ApiInvalidParameterException.class)`,
`:412` `EntityNotFoundException`, `:470`, `:484`;
`UserGroupControllerUnitTest.java:150, 216, 229, 244`.

Asserting the throw is the right call under `standaloneSetup` and the tests say so. But the entire
"honest status" claim rests on `RestExceptionHandler` being an **unscoped** `@ControllerAdvice`, and
nothing in the suite would notice if someone later added `basePackages` to it — which is precisely the
trap the PR's own javadoc calls out about the *other* advice. Ten lines close it:

```java
MockMvcBuilders.standaloneSetup(userController)
    .setControllerAdvice(new RestExceptionHandler())
    .build()
```

then assert `isUnprocessableEntity()` on the unknown-userId `saveUserGroups` case and `isNotFound()` on
the unknown-id delete. Flagged from this lane because the status table is this ticket's deliverable;
the test lane owns whether it is worth the lines.

## 9. Doc updates this PR should carry

- `sbdocs/3-Resources/architecture/wms-exception-taxonomy.md` — if F3 is declined, record the
  deliberate 422-not-409 deviation in §6 (see F3). If F3 is accepted, no change needed; the tree
  already describes what the code does.
- `sbdocs/3-Resources/architecture/wms2-keycloak-role-matrix.md:272` currently reads *"Still open, own
  ticket SBDEV-2984: /v3/user/create, /user/importUser, /user/delete/{userId}"*. SBDEV-2984 merged (PR
  #180) and `/user/delete` now carries `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)`
  (`UserController.java:355`). That line is stale — but it is stale because of **2984**, not 3012, so
  fixing it here is optional tidying, not this PR's obligation.
- No workflow or design doc under `sbdocs/3-Resources/` describes these four endpoints' response
  shapes. `wms2-function-to-docs-map.md:220` maps `UserController`/`UserGroupController` to
  `wms2-keycloak-role-matrix.md`, which documents *gating*, not contracts. So there is no
  now-incorrect contract description to repair — grepped `saveUserGroups|saveGroupRoles|userGroup/delete|user/delete`
  across all of `sbdocs/`; every hit outside the role matrix is in a plan or review doc, not a
  reference doc.

---

## RULED OUT — checked, found correct

1. **`ApiInvalidParameterException` → 422 for `net.aim_ai.wms.controller`. Confirmed.**
   `RestExceptionHandler.java:23` is a bare `@ControllerAdvice` with **no** `basePackages`,
   `assignableTypes` or `annotations` attribute, so it applies to every controller in the application.
   `:25` `invalidParameterStatus = HttpStatus.UNPROCESSABLE_ENTITY`; `:35-40` returns
   `ResponseEntity.status(422).body(ex.getErrorObject())`. The repo note that prompted the question is
   about `RestEndpointExceptionHandler` (`:37`,
   `@ControllerAdvice(basePackages = "net.aim_ai.wms.controller.rest")`), which is a *second, narrower*
   advice — its scoping does not restrict the global one. **The "honest status" claim does not
   collapse.**
2. **`EntityNotFoundException` → 404. Confirmed, and it is the right class.**
   `RestExceptionHandler.java:153-164` → 404 + `ProblemDetail{title:"Entity Not Found", detail:
   ex.getMessage(), retryable:false}`. Both services throw
   `net.aim_ai.wms.exceptions.EntityNotFoundException` (not `jakarta.persistence`'s) — verified at the
   import in each service and at the fully-qualified name in the tests — which is what the handler
   binds. `sbdocs/3-Resources/architecture/wms-exception-taxonomy.md:484` documents exactly this as the
   v2-preferred pattern.
3. **Only one `@ExceptionHandler(Exception.class)` exists** (`RestEndpointExceptionHandler.java:84`)
   and it is scoped to `...controller.rest`. Grepped for `HandlerExceptionResolver` and
   `ErrorController` — none. This is the basis of F2 and of the PR's own "bare 500" claims, and both
   are right.
4. **`saveUserGroups` 200 `{"errors":[]}` → 200 `true` breaks nothing.** Neither of its two consumers
   reads the body. Traced above.
5. **`saveGroupRoles` is genuinely unchanged** on the success path — `ResponseEntity.ok(new
   Boolean(true))` → `ResponseEntity.ok(Boolean.TRUE)` serializes identically to `true`.
6. **No consumer branches on `result` truthiness, `result.errors`, or `result.errors.length`** for any
   of the four endpoints. The two `.errors` branches that do exist in `store/admin/user.js` (`:73-80`,
   `:87-100`) belong to `/user/update` and `/user/create`, which this PR does not touch. Recorded in §2
   as the near miss.
7. **No mobile consumer.** `wms2-mobile-ui` has no admin surface; full evidence in §1.
8. **No Cypress test breaks.** The suite documents its own non-coverage of all four at
   `admin.cy.js:672` and `:874`.
9. **No automatic retry storm on the new 4xx.** `plugins/axios.js:53-54` returns `false` for any status
   other than 401/403, so 422/404 are never retried and the `onMaxRetryTimesExceeded` forced-logout
   path is unreachable from them. `$axios.onError` (`:200-207`) only re-rejects.
10. **`UserGroupController` is gated** — class-level `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)`
    at `:43` covers `/delete/{groupId}` and `/saveGroupRoles`, so the 404 change does not expose group
    existence to an unauthenticated caller. (Enforcement depth is the authz lane's call; I only
    checked that the annotation is present.)
11. **An empty `groups: []` / `roles: []` is accepted, not rejected** — correct. `userGroupEdit.vue:66-74`
    resets `itemsInEdit` to `[]` when a user has no groups, so "revoke everything" is a real,
    reachable UI action and a 422 there would have been a regression.
12. **Ids above `Integer.MAX_VALUE`** no longer `ClassCastException` into a bare 500 —
    `requiredId` accepts any `Number` and widens. Pinned by
    `UserControllerUnitTest.shouldAcceptLongIds` with `3_000_000_000L`.
13. **`MAX_*_PER_REQUEST = 500` is not reachable by the UI.** Both dialogs render one `v-switch` per
    row from `getGroups` / `getRoles`; hydra-uat has 29 groups. No legitimate client can trip the bound.
14. **`existsById` does not materialise the EAGER collections.** It issues an existence query, not a
    load, so the `User.groups` / `UserGroup.roles` hazard the javadoc describes is genuinely avoided by
    putting the check in the controller. (Whether the *service* stays clean is the tx lane's.)
15. **The `catch (DataIntegrityViolationException)` in `delet` will actually catch.**
    `deleteUserById` is a `@Modifying` bulk JPQL delete, so the statement executes at the repository
    call and Spring Data's exception translation turns Hibernate's `ConstraintViolationException` into
    `DataIntegrityViolationException` there. Even if a deferred constraint pushed it to commit,
    `JpaTransactionManager` translates a `RollbackException` whose cause is convertible to the same
    type. Reasoned, not executed — see below.

## Could not verify

- **No endpoint was called.** No app instance was started and no request was issued, so every status
  code in this review is derived from reading `RestExceptionHandler`'s scoping and mappings, not
  observed. The one that would most repay a single curl is `GET /v3/user/delete/{id}` against a
  hydra-uat user with history: it exercises F1, F2's absence, F3 and RULED-OUT #15 in one call, and
  the response body is the thing F1 is about.
- **F4's Vuex behaviour** (unknown action → console error + `undefined`, no throw) is from Vuex's
  documented semantics, not from running the app. The *absence* of the `admin/userGroup` namespace is
  proven from the filesystem and the absent `registerModule`; only the runtime consequence is inferred.
- **Whether `DataIntegrityViolationException` is the type that actually arrives** on a real
  hydra-uat FK violation (RULED-OUT #15). The unit test at `UserControllerUnitTest.java:396` stubs the
  exception rather than provoking it, which is unavoidable in a unit test but means the type is
  assumed. If it arrives as `TransactionSystemException` instead, the `catch` misses and the endpoint
  bare-500s — the exact failure mode this ticket exists to remove. One curl settles it.
- **SBDEV-3030's scope.** Taken from the lane brief; I did not open the ticket.
