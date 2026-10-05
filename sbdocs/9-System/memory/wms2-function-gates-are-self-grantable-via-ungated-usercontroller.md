---
name: wms2-function-gates-are-self-grantable-via-ungated-usercontroller
description: "STALE/CORRECTED 2026-10-01: UserController and UserRoleController are class-gated by WEB_UI_VIEW_USER_MANAGEMENT and in FunctionGuardInterceptor.GUARDED; saveUserGroups is gated"
metadata: 
  node_type: memory
  type: project
  originSessionId: d594027c-8456-4059-886b-9bb9c11c997b
  modified: 2026-08-17T19:20:29.868Z
---
> **STALE / CORRECTED 2026-10-01.** The claim "UserController carries zero authorization" no longer holds on `origin/develop`. `UserController.java:86` is `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_USER_MANAGEMENT)` (class level) and `UserRoleController.java:44` carries the same annotation. Both are listed in `FunctionGuardInterceptor.GUARDED` (`UserRoleController.class`, `UserController.class` entries). `saveUserGroups` (`UserController.java:556`) opens with `denyUnlessUserManagementAllowed();  // SBDEV-2870 — must precede every repository call`. Two `@PublicHandler` bootstrap reads (`isWmsUser`, `getAllRoles`) are deliberately ungated. Not re-verified here: the claim that `create`/`importUser`/`delete` are gated (class-level annotation covers them by the interceptor's class-level fallback, but no per-handler test was run). The text below is the 2026-08-17 finding, kept as history. Verified by `git grep`/`git show` on `origin/develop` 2026-10-01.


`v2/wms2-api` `UserController` carries **zero** `@PreAuthorize` and **zero** function checks across all 12 of its endpoints (`grep -c` returns 0 for both). Its only gate is the `/v3/**` → `hasAnyAuthority("wms_user")` floor.

`POST /v3/user/saveUserGroups` (`UserController:263-286`) takes `userId` + `groups` from the request body, **deletes every** `mywms_group_mywms_user` row for that user, then inserts the supplied ones. That table is exactly what `AccessService.doesUserHaveAccess` traverses (`UserRepository:27-34`).

**Why this matters:** it makes *every* function-based gate self-grantable. Any `wms_user` can give themselves the `super-admin` group in one request and walk through any `doesUserHaveAccess` check; or send `{"userId": <admin id>, "groups": []}` to strip a real administrator of every function, locking a tenant out of User Management. Found by code review on SBDEV-2870 (2026-08-17) and independently confirmed; recorded as that plan's §10.9.

Same class of hole for identity creation (§10.10): `POST /v3/user/create` is ungated and calls `KeycloakService.createSingleUser`, which at `:716-724` adds the account to **both** the WMS group and the warehouse group — reproducing what `importUsersFromCsvText` was gated on `wms_admin` for. `/v3/user/importUser` (`:78`) and `/v3/user/delete/{userId}` (`:234`) are likewise ungated.

**How to apply:**
- Do NOT claim a function gate closes a hole until the write side of `mywms_group_mywms_user` is also gated. Any such acceptance criterion is false while `saveUserGroups` is open.
- The fix is cheap: `UserController` is a **leaf** (nothing extends it), so injecting `AccessService` into its constructor does not ripple — unlike [[wms2-admincontroller-is-a-base-class-for-43-controllers]]. Sibling methods on `AdminController` already use `@PreAuthorize(IS_SB_ADMIN)`, so the class is already proxied.
- Generalisable: gating on a DB table is only as strong as the weakest writer of that table. Enumerate the writers, not just the readers.

Related: [[wms2-only-one-of-80-functions-is-enforced]], [[sbdev-2870-function-model-not-group-axis]]
