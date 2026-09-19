---
name: wms2-13-action-gates-are-self-grantable-and-sdr-bypassable
description: SBDEV-2967-C's 13 controller gates close only the audited route — SDR still exposes the group/role join tables for self-grant, and /v3/stockunit PATCH reaches the same fields ungated
metadata:
  type: project
---

Measured by an independent security lane on SBDEV-2967-C, 2026-08-22, against the production
`RepositoryRestConfigurer`. Both are PRE-EXISTING, neither is caused by that slice.

**Both now live on [[SBDEV-3017]]** (`868kufdy1`, raised to high) — filed as a WIDENING, not a new ticket:
3017 is "SDR endpoints are ungatable" and its Class A already owned the mechanism, even citing
`PATCH /v3/stockunit/{id}` as the precedent. Search-then-widen found it; a new ticket would have split one
fix visit in two. Worth remembering as the worked example of that policy paying off.

**S-1 — the gates are self-grantable, possibly in one request.** Every access decision comes from
`UserRepository.getAllRoles`, which traverses `user → group → role → function`. SBDEV-3013 door ① withdrew the
SDR write verbs from the **last hop only** (`mywms_role_mywms_function`). Still exposing POST/PUT/PATCH/DELETE:
`mywms_group_mywms_user`, `mywms_group_mywms_role`, `mywms_user_mywms_role`, plus the `User.groups` and
`UserGroup.roles` associations. So `PATCH /v3/userGroup/{aGroupIBelongTo}/roles` with a privileged role's URI,
then the gated endpoint returns 200. `FunctionGuardInterceptor` structurally cannot see it —
`RepositoryRestHandlerMapping` does not consult `WebMvcConfigurer#addInterceptors`.

Fix is ~20 lines in `RestConfiguration.configureRoleFunctionWriteExposure` + `SdrWriteExposureUnitTest`.
🔴 **LANDMINE: do NOT disable item PUT on `UserGroup`/`UserRole`.** `store/admin/group.js:69` and
`store/admin/role.js:85` issue `PUT /v3/userGroup/{id}` / `PUT /v3/userRole/{id}`, and NEITHER controller
declares a `@PutMapping` — those are live SDR item writes serving the admin screens. The three join-table
aggregates and the two associations are client-free (grepped both UIs) and safe. Residual that exposure config
cannot close: SDR deserializes association URIs in an entity body, so `PUT /v3/userGroup/{id}` with
`{"roles":["/v3/userRole/{privileged}"]}` is a second route — needs an event handler, or moving group/role
edit onto the gated controller where `saveGroupRoles` already lives.

**S-2 — the gated CAPABILITY has an ungated, unaudited path.** `/v3/stockunit` and `/v3/unitload` retain all
four SDR write verbs; `amount`, `reservedamount`, `entityLock` have public setters with no `@JsonIgnore` /
`@ReadOnlyProperty`. Every layer was checked and **nothing rejects** `PATCH /v3/stockunit/{id} {"amount":0}`.

🔴 **The 500 everyone cites is not evidence of refusal.** `RestConfiguration` sets
`setReturnBodyForPutAndPost(true)`, and the transaction commits when `SimpleJpaRepository.save()` returns —
*before* the message converter runs. A 500 during response rendering means **the write committed and only the
response failed**. Schema-proven instance: `reservedamount` is nullable with no `@NotNull` while
`getAvailableamount()` calls `amount.subtract(reservedamount)` unconditionally, so
`PATCH {"reservedamount": null}` validates, commits, then NPEs on serialize. The recorded 500 was measured on
`{"entityLock":103}` — a different column — so it never transferred. **When testing: use `{"amount":0}`, and
judge by re-reading the row (`amount, reservedamount, version`), never by the status code.**
`/v3/unitload/{id}` PATCH+DELETE have never been measured in either direction.

Also unresolved before deploy: the Cypress e2e suite POSTs to five of the gated endpoints asserting 200, and
no principal is pinned in `cypress.config.js` — it will red on deploy unless the e2e user holds the five
`WEB_UI_ACTION_*` functions. See [[wms2-only-one-of-80-functions-is-enforced]],
[[wms2-function-gates-are-self-grantable-via-ungated-usercontroller]], [[wms2-sdr-association-resource-verb-reality]].
