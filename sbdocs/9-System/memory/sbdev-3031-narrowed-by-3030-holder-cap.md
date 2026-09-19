---
name: sbdev-3031-narrowed-by-3030-holder-cap
description: SBDEV-3031 ("groups holding this role" view) lost most of its premise when SBDEV-3030 landed; residual gap is only holders past the cap of 5
metadata:
  type: project
---

SBDEV-3031 asks for a "groups holding this role" view in `wms2-web-ui`, justified as "the only
route from refused to resolved" because the 422 was discarded. **That justification expired on
2026-08-29.** SBDEV-3030 merged as `cdaf9b0` (head of `wms2-web-ui` develop): `store/admin/role.js:146-167`
now returns true/false and toasts the real 422 body, and `deleteRolePop.vue:57-75` keeps the dialog
open on failure. And the 422 already *names* holders — `UserRoleService.describeHolders:295-305`.

**RESOLVED 2026-08-29 by raising the cap, NOT by building the view.** Nam chose that route. Two
local branches, unpushed: `wms2-api feature/SBDEV-3031-holder-message-cap` (`1b2dce11`) and
`wms2-web-ui feature/SBDEV-3031-render-refusal-in-dialog` (`0d82836`).
⚠ **Merge the API half FIRST** or the UI fixtures describe a body the deployed API cannot produce.
⚠ The ticket's TITLE still says "add a groups-holding-this-role view" — that was NOT built.

**Survey the whole tenant population, not one tenant in two environments.** My first pass said
"both tenants" and meant PRD hydra + UAT hydra = 2 of **5** tenant DBs. Complete population (from
the PRD landlord's 1 active row + the UAT landlord's 4): PRD `wh01_hydra_v2` 9 roles/0 over/max 3;
UAT `wh01_hydra_v2` 14/1/**16**; UAT `wh01_om1_v2` (WineCo) **137**/2/9; UAT `wh01_shipitez_v2`
9/1/12; UAT `wh02_shipitez_v2` 9/1/10. **Five** roles over the old cap of 5 across **four** of the
five DBs. Zero rows in `mywms_user_mywms_role` on all five — direct user→role grants do not exist,
so the 422's `Users:` side is always `none`. See [[wms2-direct-user-role-assignment-is-unused]].

**Raising the cap alone did NOT deliver the outcome** — a review lane caught this and it was the
single most valuable finding. The 322-char body had ONE channel and no fallback: `$toast.error` on a
**global 4500 ms timer with no close button** (`nuxt.config.js:95`), while `logApiFailure`
deliberately logs no response body and the API's WARN (`UserRoleService:291`) logs only the counts.
Fix: render it in `deleteRolePop.vue`, which SBDEV-3030 already made persistent. **Generalise: when
a fix's value is "the operator can now see X", verify the channel X arrives in.**

**Landmine — dominant, not marginal, and it inverts the ticket's own prescription.** The ticket says
to join group names client-side from the Vuex store, but `store/admin/group.js:110-112` fetches
`/userGroup/search/findByConnectorFalse` — **connector-false only**. Measured on UAT: **22 of 29
groups are `connector = true` and all 22 hold a role** (PRD: 2 of 9). Worse, `super-admin`'s 16
holders are **1 connector-false + 15 connector-true**, so the prescribed join renders 1 name and 15
blanks *for the only role in scope*. Fetch unfiltered `/userGroup`, or render unresolved ids as
`id <n>` the way `UserRoleService.format` does.

**Handle identity (verified, do not trust the names):** `nywh-hydra-uat` = UAT (`wh01_hydra_v2` as
`wh03_om1`, 14 roles); `wms2-hydra` = **PRD** (same db name, user `wh01_hydra_v2_app`, 9 roles).

The "no API work needed" premise survived SBDEV-3157 (which withdrew SDR **write** verbs only —
`RestConfiguration.java:184-186` keeps GET on `UserGroupUserRole`, and it is in `exposeIdsFor` at
`:402-408`). SDR is still ungated: see [[wms2-sdr-is-gatable-via-mappedinterceptor-bean]].

Related: [[sbdev-3030-admin-error-body-and-guard-mutation-trap]],
[[sbdev-3011-delete-role-join-table-cascade]],
[[wms2-web-ui-develop-preexisting-suite-failures]] (the ticket's "2 always-red suites" landmine is stale).
