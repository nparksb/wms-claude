---
name: sbdev-3005-role-function-composite-key-swap
description: "SBDEV-3005 — no function can be added to any role in wms2; composite-key components reversed, one sibling call site reversed too so the swaps cancel"
metadata: 
  node_type: memory
  type: project
  originSessionId: 06947b5e-b469-4ffe-99d7-c41704a80bab
  modified: 2026-08-19T20:03:05.236Z
---

**SBDEV-3005** (filed 2026-08-19; reviewed by two independent lanes; **MERGED 2026-08-20** — [wms2-api #170](https://github.com/SiteBossInc/wms2-api/pull/170), merge commit `60aef02` into `develop`; verify `39 pass, 0 fail, 2 skip`, 80 gate tests, full suite 5172 with the 2 known pre-existing failures. Reviewed by 2 lanes pre-implementation and 2 post; manual tests M4/M8 NOT run; P2 prd audit open; H1 ungated-write deferred to SBDEV-2967/2968; follow-ups SBDEV-3010..3014 filed).

**DEPLOYMENT CHECK — use the log, not the ticket status.** A deploy on 2026-08-19 reproduced the original error because PR #170 was still open and the image built from pre-fix `develop`. The tell is the log line `delete printer with Id null`: Fix E deletes it, so **if that line appears, the running image predates the fix**, whatever the board says. Generally: `pr submitted` means submitted, not merged — verify with `gh pr view --json state,mergedAt` and by grepping `origin/develop`, not the branch.. `UserRoleUserFunctionId` declares `(rolelistId, functionlistId)` but `UserRoleController:98` and `UserFunctionService:51` both construct it reversed, so the FUNCTION id lands in `rolelist_id` and trips `fkby47oyt3v45jq6sysqya4til9 → mywms_role(id)`. Every role→function grant 500s.

Introduced by **`5442a06a` (2025-12-23)**, the Spring Boot 3.5 `@IdClass`+setters → `@EmbeddedId` positional-`record` conversion. The rewrite preserved the **textual order of the setter lines** instead of the record's component order. This was the only one of five composite-id records whose setters happened to run function-first, which is why exactly one of them broke and the three sibling join tables are genuinely safe — not luck needing re-checking.

**LANDMINE 1:** `AccessService:146` (`addFunctionToGroup`) is reversed at the *call site* too, so the two swaps cancel and that path writes CORRECT rows today. Fixing `UserFunctionService` alone silently breaks it. `AccessService:102`/`:127` pass the declared order and are broken.

**LANDMINE 2:** `AccessServiceUnitTest:284` was **pinning** the reversed call as correct behaviour, so a lone fix makes an existing green test go red and invites reverting the fix.

**The atomicity fix is a SET DIFFERENCE, not delete-all-then-reinsert** — see [[hibernate-delete-then-reinsert-same-key-needs-set-difference]]. Also: `/rest/util/initAdmin` is NOT live either ([[wms2-utilrestcontroller-is-service-not-restcontroller]]), so the only live broken path was `POST /v3/userRole/saveRoleFunctions`.

**Secondary data-loss defect:** no `@Transactional` on `UserRoleController` or its base `AdminController`, so each Spring Data `delete()` in `saveRoleFunctions` commits before the failing insert — one bad save leaves the role with ZERO functions. Never put `@Transactional` on `AdminController` (base class of 43 controllers); see [[wms2-admincontroller-is-a-base-class-for-43-controllers]].

**No data repair needed:** 8 of 9 v2 tenants audited, 0 corrupt rows. But `wms2-hydra-v2t` and `nywh-shipitez-uat` each already have one id shared between `mywms_role` and `mywms_function` (v2t: id 579 = role `inventory-manager` AND function `MOBILE_UI_VIEW_CANCELLATION`). The next collision turns this from a loud 500 into a **silent authorization misgrant**, because both columns are plain bigint FKs.

`/rest/util/initDB`'s 138 `addFunctionToRole` calls are dead code (requester confirmed, slated for deletion) — out of scope. `/rest/util/initAdmin` is dead too, for the separate `@Service` reason above.

**Likely a prerequisite for SBDEV-2967 / SBDEV-2968** ([[wms2-only-one-of-80-functions-is-enforced]]): enforcement assumes functions can be *assigned*, and today only the migration base dump can assign them.

**🔴 STILL BROKEN AND DESTRUCTIVE ON PRODUCTION as of 2026-08-21.** `60aef02` is on `origin/develop`
and `origin/release` but **NOT on `origin/main`**, which prd tracks — verified with
`git merge-base --is-ancestor 60aef02 origin/main` → NO, and `origin/main`'s `UserRoleController:98`
still constructs `new UserRoleUserFunctionId(functionId, roleId)` against the unchanged
`(rolelistId, functionlistId)` record, with the deletes still un-transacted.

So on prd, pressing **Save on a role's functions deletes every grant on that role and then 500s** with
a toast reading *"network or server issue, please retry"* — which invites a retry that does nothing.
Prd has 0 orphan rows today, consistent with the button never having been pressed there: the hazard is
LATENT, and any ticket that gives an admin a reason to adjust grants is what fires it.

**Consequence for [[sbdev-2967-split-into-slices]] slice B:** §7.1 discharged the grant-table sign-off on
"grants are adjustable afterwards via Admin → User Management with no deploy, because SBDEV-3005 is
deployed". That is a `develop`/`release` property, not a `main` one. Post-gating, doing this to
`super-admin` on prd strips `WEB_UI_LOG_IN` from all 7 production humans and locks the tenant out of the
web UI with **no in-app recovery** — `AccessService` has no `sb_admin` bypass, so even SiteBoss staff are
denied, and repair needs direct SQL. **Gate rule: never deploy a function-gating slice to an environment
whose api lacks `60aef02`. Verify with `git merge-base`, never by reading a plan sentence.**
