---
name: wms2-join-table-uniqueness-is-out-of-band
description: The v2 migrations declare no unique constraint on any of the four mywms_* authorization join tables; every unique index in the estate was hand-applied — and PRD HAS NONE OF THEM, so prd is the LEAST protected tenant, not a protected one
metadata:
  type: reference
---

`db/migration/` creates 53 tables; **6 have no primary key**, four of them the authorization join tables `mywms_group_mywms_role`, `mywms_group_mywms_user`, `mywms_role_mywms_function`, `mywms_user_mywms_role` (plus `message_archived`, `shippingmethod_shipperid`).

**More precisely — and this is the part that matters: the migrations declare ZERO unique indexes on all four.** The composite indexes on two of them are non-unique, so they look like protection and provide none. `mywms_user_mywms_role` gets **no index whatsoever**.

Live tenants diverge, all of it hand-applied (the `_pk` / `_pkey` / `_uindex` naming split is the evidence):

| table | hydra **PRD** | hydra-uat | wsl-wineco-uat | shipitez nywh-uat |
|---|---|---|---|---|
| `mywms_group_mywms_role` | **NOTHING** | UNIQUE index | `_pkey` | **NOTHING** |
| `mywms_group_mywms_user` | **NOTHING** | UNIQUE index | `_pkey` | **NOTHING** |
| `mywms_role_mywms_function` | **NOTHING** (1 non-unique idx) | `_pk` | `_pkey` | — |
| `mywms_user_mywms_role` | **no index at all** | **nothing** | **nothing** | — |

**CORRECTED 2026-08-21 — measure PRD, not UAT.** The earlier version of this note said "3 of 4 are in
practice safe on live tenants", from hydra-uat only. **On hydra PRD not one of the four has any
uniqueness**, and `mywms_role_mywms_function` has no `_pk` there either. Prd is in exactly the state a
fresh Flyway tenant is in — i.e. **the least protected tenant in the estate, not a protected one**.
This wrong belief propagated into SBDEV-3012's code comments and PR before a review caught it; see
[[sbdev-3012-user-group-write-atomicity]].

**Still don't overstate it — measured 2026-08-21, nothing is broken today:**
- **Zero duplicate pairs** on hydra PRD, wineco DEV and shipitez nywh UAT.
- **Authorization is immune**: `UserRepository.getAllRoles`, the query behind every
  `doesUserHaveAccess`, is `SELECT DISTINCT f.name`.
- **The admin UI is immune**: memberships come from `GET /v3/user/{id}/groups`, which serialises
  `User.groups` — a `Set`, so duplicates collapse and nothing double-renders.

These entities use `@EmbeddedId`, so the ordinary single-threaded application path is protected. What a
DB constraint actually buys:

1. **Concurrency — SIX check-then-act sites, not the two originally listed.** `addRoleToFunction`,
   `addGroupToRole`, `addUserToGroup` (all `findByXAndY` then `save`), plus SBDEV-3012's
   `UserGroupService.replaceGroupRoles` and `UserService.replaceUserGroups`, which read the existing
   set and insert only the difference. Hibernate's identity map is per-persistence-context, so two
   replicas both pass the guard and both insert. Only a DB constraint closes that window.
2. **Non-Hibernate writers** — the base dump's own raw `INSERT INTO public.mywms_role_mywms_function VALUES …`, psql-provisioned tenants, hand-run hotfixes, and the Spring Data REST endpoints.
3. **Reproducibility** — a tenant built from `db/migration/` gets none of the protection the running estate relies on.

**Landmine:** any plan arguing "the PRIMARY KEY will catch a duplicate insert" is **unsound on a migration-built database**, and no migration-built integration test can demonstrate duplicate-key behaviour. This invalidated an argument in [[sbdev-3005-role-function-composite-key-swap]]. Tracked as **SBDEV-3010** (`Open`, `normal`) — widened 2026-08-21 with the prd correction rather than
filing a second ticket, since it already owns this code-path visit. Next free migration version was
**V2.2.19** at that date (`V2.2.18` is already on develop — the ticket's own "V2.2.16 is the head" note
had gone stale, so re-sweep all remote branches at implementation time). Applying it needs a per-tenant
per-table duplicate pre-flight on dev, UAT **and prd**: an `ALTER TABLE` that fails freezes that
tenant's whole Flyway chain, silently, because tenant migration failures never abort boot.
