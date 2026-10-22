---
name: sbdev-3011-delete-role-join-table-cascade
description: SBDEV-3011 deleting any role destroyed its grants then 500'd; PR #173 MERGED 2026-08-21 (on dev) — refuses with 422 instead of cascading, and closed the parallel SDR delete route; never confirmed behaviourally because the check is destructive
metadata:
  type: project
---

**SBDEV-3011 (v2) — `on dev`. [wms2-api #173](https://github.com/SiteBossInc/wms2-api/pull/173) MERGED 2026-08-21 as `7d0fd13`**; DEV redeployed healthy. Commits `96ad273` + `6e75c8a` + `982df3b`. Verify `54 pass, 0 fail, 1 skip` pre-merge; `48 pass / 1 fail` post-merge, the one red being a stale-baseline row, not a regression.

**It was never confirmed behaviourally, and that is a standing gap, not an oversight** — the only check that exercises the fix deletes a live role, so it was not run on any environment. Suite + compile + deploy is the whole evidence base. If you need live confirmation, create a throwaway role first and record grant counts before and after.

`GET /v3/userRole/delete/{roleId}` cleared only `mywms_role_mywms_function` — one of **three** tables that FK to `mywms_role(id)` — with no transaction, so it destroyed the role's whole grant set and then 500'd on the FK. **`roles_deletable_today = 0` on hydra-uat: all 14 roles were group-held, so it failed for EVERY role**, and one click on `super-admin` destroyed 77 grants across 16 groups.

Fix = **refuse with 422 naming holders, not cascade** (Nam's decision — a cascade silently revokes permissions from every member of every holding group, unrecoverably) + one `tenantTransactionManager` tx + two **bulk JPQL** deletes so no entity is materialised + withdrawing the parallel SDR `DELETE /v3/userRole/{id}`.

**LANDMINES for anyone touching this area:**
- `deleteById` calls `findById`, which eagerly loads `UserRole.functions` — a second `@ManyToMany` over the table just emptied — so its `CollectionRemoveAction` races the pending entity deletes. Use bulk JPQL, never `deleteById`, in any method that also clears that join table.
- `mywms_user_mywms_role`'s component is **`rolesId`/`roles_id`**, NOT `rolelistId` like its three siblings. Copying a sibling's query fails at application startup.
- `clearAutomatically` on `@Modifying` detaches the caller's ENTIRE persistence context. 4 of 7 local bulk-delete precedents set it; do not copy them. 5 of 7 also carry `@Transactional` and 3 are BARE → the `@Primary` **landlord** manager.
- `UserGroup.name` has no `@NotNull`, so never derive an authorization verdict from a name lookup.
- Still open, each with an owner: the SDR **association** resource (see [[wms2-sdr-association-resource-verb-reality]]), `UserGroupController.delete/{groupId}` (owner resolved 2026-08-20 by **widening SBDEV-3012**, which is now unblocked since #173 and #180 both merged), and `UserController.delet` which returns **HTTP 200 on failure** while missing 9 operational `operator_id` FKs (soft-delete design → SBDEV-3021; its *authorization* half is now closed by SBDEV-2984, PR #180 `dc56849`).
- Operator-visible impact is currently **nil**: every role is held so every call 422s, and `store/admin/role.js:110-119` discards the body for a hardcoded toast. Related: [[sbdev-3005-role-function-composite-key-swap]], [[wms2-only-one-of-80-functions-is-enforced]].
