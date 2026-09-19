---
name: wms2-putaway-config-is-sb-admin-only
description: "Every Default Putaway Location writer is gated on sb_admin, so no customer user can configure any tier — contradicting SBDEV-2643's own stated permission model"
metadata: 
  node_type: memory
  type: project
  originSessionId: 15746052-ae44-4afd-b8c8-c905718fbdb5
  modified: 2026-08-26T00:36:14.683Z
---

Found 2026-08-25 while triaging SBDEV-2956/2960. Every write path for the putaway destination
hierarchy is gated on **`sb_admin`** — `PutawayConfigService`'s three writers all carry
`@PreAuthorize(Authority.IS_SB_ADMIN)`, and both UI affordances use `:disabled="!isSbAdmin"`
(`skuData.vue:123` and `:177`).

`sb_admin` is the SiteBoss super-admin on the Keycloak `groups` claim — staff only (see
[[sb-admin-is-siteboss-super-admin-via-groups-claim]]). So **no customer user can configure a
Default Putaway Location at any tier**, and the non-admin tooltip says so: *"This setting is
managed by SiteBoss support."*

That contradicts SBDEV-2643's own Permissions section, which specifies "users with appropriate
warehouse inventory or **configuration permissions**" — a different axis from a staff escalation.
The practical effect is that the feature built to stop people editing the DB directly still needs
SiteBoss for every change: on `dev_wh01_om1` all 3 typed writes in `putaway_config_audit` are the
same operator, and 8,803 of 8,805 SKUs are unconfigured.

It also makes SBDEV-2956's AC "read-only users can see the field but cannot edit it" pass for the
wrong reason — *everyone* is read-only.

**Reads are deliberately ungated** (`wms_user`): `GET /v3/itemData/{id}/effectivePutawayDestination`
and `GET /v3/putawayConfig/eligibleLocations` are both open. Only the writes are privileged — which
is why a display-only fix for SBDEV-2956 needs no permission work.

**Not resolved** — raised as a comment on parent SBDEV-2643 for David/Nam, deliberately not filed as
a new ticket. Two candidate directions if the posture isn't intended: move the gate to a function in
the `FunctionGuardInterceptor` programme (⚠ **CORRECTED 2026-09-01: this is no longer develop-only.**
`FunctionGuardInterceptor` is present at tag `v0.0.21`, the build actually running on prd, and
`origin/main` shipped v2.0.137 / wms2-api v0.0.22 on 2026-09-01 16:27. The superseded memory that said
otherwise has been deleted; for what is actually DEPLOYED versus what is on `main`, see
[[wms2-deployed-image-differs-from-branch-head]] and check `/api/public/version`), or move to
`wms_admin`, the way
SBDEV-2870 did after finding `sb_admin` would 403 customer admins out of User Management. If the
current posture *is* deliberate, the fix is wording — the ticket's Permissions section should say
`sb_admin` / SiteBoss-managed so the next reader doesn't score it as a defect.
