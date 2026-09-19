---
name: wms2-direct-user-role-assignment-is-unused
description: The direct user→role assignment (mywms_user_mywms_role / UserUserRole / SDR userUserRole) is NOT used by WMS v2 — a direct grant confers zero functions because the access query only walks user→group→role→function
metadata:
  type: project
---

**Nam, 2026-08-24:** the direct user↔role assignment is **no longer used for WMS v2**. (Referent: the
`mywms_user_mywms_role` table / `UserUserRole` entity / SDR `userUserRole` resource — not any single
named role.)

**Why it matters — a direct role grant is invisible to authorization.** The authoritative access query
`UserRepository.getAllRoles` (`repo/jpa/UserRepository.java:29-37`, native SQL, used by
`AccessService.checkAnyAccess`) walks **only**:

```
mywms_user → mywms_group_mywms_user → mywms_group_mywms_role → mywms_role_mywms_function → mywms_function
```

It never touches `mywms_user_mywms_role`. So inserting a row there grants **nothing** — functions come
exclusively through a **group**. Corroboration: 0 rows on wineco dev (2026-08-24), and
`controller/UserController.java:402` already records "empty on every tenant checked 2026-08-21, so
latent"; **SBDEV-3021 owns that table**.

**How to apply:**
- Never diagnose a permissions problem from this table, and never try to fix a missing function by
  inserting into it. Provisioning is user → **group** → role → function. See
  [[wms2-only-one-of-80-functions-is-enforced]] for the enforcement side.
- It is **not** an escalation route even though SDR leaves it writable — I nearly filed it as a third
  door alongside the two [[wms2-access-chain-hops-1-2-writable-over-sdr]] describes, and the
  `getAllRoles` query is what disproved it. Confirm reachability of the *decision*, not just the write.

**The only v2 code that reads it** is defensive, in `UserRoleService.deleteRole` (`:242`
`findByRolesId`, joined with the group holders to build the 422 refusal), plus the user-delete FK
conflict path. Both read-only.

**Live liability on dev (low severity, no escalation):** SDR still exposes the write surface —
`OPTIONS /v3/userUserRole` → `Allow: HEAD,POST,GET,OPTIONS`, and
`DELETE /v3/userUserRole/{nonexistent}` returns **500** instead of 404. Dead table + writable
endpoint, so withdrawing its write verbs in `RestConfiguration` is pure upside; note
`UserUserRoleId`'s components are `(userId, rolesId)` — `rolesId`, **not** `rolelistId` like its three
siblings (`repo/jpa/UserUserRoleRepository.java:19-22`).
