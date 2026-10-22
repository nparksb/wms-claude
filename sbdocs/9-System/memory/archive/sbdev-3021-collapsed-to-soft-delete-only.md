---
name: sbdev-3021-collapsed-to-soft-delete-only
description: SBDEV-3021 CLOSED 2026-08-28 — the 422 from SBDEV-3012 was accepted; no soft delete
metadata: 
  node_type: memory
  type: project
  originSessionId: 4afc322a-0e0b-493a-9bfe-45f0ae03aea9
  modified: 2026-08-28T17:10:10.060Z
---

SBDEV-3021 ("deleting a user with warehouse work is impossible — needs a soft-delete design")
offered **three** options. Two of them are **already live on `origin/develop`**, shipped by
SBDEV-3012 (triaged 2026-08-28 at `2f82c473`):

- **Option 3 — hard delete when unreferenced, 422 otherwise** — IS the current behaviour.
  `UserController.delet:485` → `UserService.deleteUser` (`service/UserService.java:276`), one
  `tenantTransactionManager` transaction, bulk JPQL, no `deleteById`. Unknown id → 404; a user
  with operational history → 422 from the `DataIntegrityViolationException` catch at `:494-517`.
- **Option 2 — refuse with 422** — live, but **without** its "naming the blocking references"
  half. The message is deliberately generic ("still referenced by other records") because that
  catch is reachable by three routes (the nine `operator_id` FKs, an uncleared
  `mywms_user_mywms_role` grant, a concurrent membership insert).

**CLOSED 2026-08-28.** Nam accepted the shipped 422 — no soft delete, no `active` flag, no
Flyway migration, no plan document. Accepted consequence: a departed employee stays on the admin
user list permanently (15 of 19 accounts on nywh-hydra-uat). They hold no group memberships and
therefore no authorization, so it is a tidiness cost, not an access-control one; revoking login
is still a Keycloak action. Reopen only if the list clutter becomes a real complaint — it would
be T3.

⚠ **The accepted behaviour is `develop`-only.** SBDEV-3012 is at status `on dev`, so on prd the
old contract is still live: the un-transacted delete that strips group memberships and answers
HTTP 200 "<id> DELETED" while the user survives. See
[[wms2-gating-programme-is-live-on-prd]].

Do not re-plan this as a three-way design choice — the ticket text predates 3012 and reads as if
nothing shipped.

**Tier was T3** had option 1 been chosen, on four independent triggers: `mywms_user` has **no**
`active`/`deleted_at`/`enabled` column (15 columns, verified `information_schema` on
nywh-hydra-uat) so it needs a Flyway `V2.2.x`; authorization-adjacent; multi-repo (api +
web-ui admin list); **78 `userRepository` call sites across 21 files**, of which `findByName`
is 41 and is the operator-resolution path that must NOT be filtered.

**Two gaps the ticket never mentions:**
- `KeycloakService` has **no disable capability** — `deleteUserByUsername:287` and group
  add/remove exist, but no `setEnabled`. Keycloak is the IdP, so a WMS-only flag does not block
  login. See [[wms2-authz-axis-keycloak-coarse-functions-fine]].
- The admin list is **one query** — `userRepository.getDetails()` behind
  `GET /v3/user/getDetails` — so hiding from the screen is cheap; blocking login is not.

DB, fresh 2026-08-28 on nywh-hydra-uat (unchanged from the 2026-08-21 figures): 19 users,
**15 blocked** by operator history, 4 deletable, `mywms_user_mywms_role` still **0 rows**.

Not filed, unowned: naming the blocking counts in the 422. Lands
invisibly today though — [[wms2-gating-programme-is-live-on-prd]] context
plus SBDEV-3030, which records the admin stores discarding every API error body for a
hardcoded generic toast.

Related: [[sbdev-3012-user-group-write-atomicity]], [[sbdev-2984-usercontroller-gated-but-sdr-user-still-writable]], [[sbdev-3011-delete-role-join-table-cascade]]
