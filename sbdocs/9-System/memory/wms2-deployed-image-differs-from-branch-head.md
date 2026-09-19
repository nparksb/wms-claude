---
name: wms2-deployed-image-differs-from-branch-head
description: wms2-api prd tracks `main`, but main's HEAD and the running prd image drift BOTH ways within a day — read /api/public/version
metadata:
  type: project
---

**The promotion flow is `develop` → `release` → `main`, and prd tracks `main`.** That part of the
Flyway runbook was always right — see [[flyway-runbook-covers-dev-and-uat-via-env-flag]].

**But `origin/main` HEAD is NOT the deployed image, and it drifts in BOTH directions within one day.**
Measured 2026-09-01 on wms2-api:

| Time | prd running (`/api/public/version`) | `origin/main` HEAD | |
|---|---|---|---|
| ~15:00 | 0.0.21 (tops at V2.2.21) | v0.0.17 (V2.2.16) | main **BEHIND** prd |
| ~16:30 | 0.0.21 (unchanged) | v0.0.22 (V2.2.23) | main **AHEAD** of prd |

main lagged because the promotion merge had not run; two hours later it led because the deploy had
not run. Both are normal mid-cycle states, not errors.

**Why this burned me:** at 15:00 I read `origin/main` (v0.0.17), saw prd running 0.0.21, and concluded
"prd must deploy from `release`, not `main`". I then "corrected" the runbook, the memory and
`apply-pending-tenant-flyway.sh` on that inference. All three were reverted when main was promoted at
16:27 and 0.0.21 turned out to be an ancestor of main after all. **A snapshot of a moving ref is not a
model of the branching flow** — and a single observation that contradicts documented process is more
likely mid-cycle timing than a wrong doc.

**How to apply:** to know what production runs, read `https://wms-api.sbo.li/api/public/version` and
check out the **tag matching that version** — never assume a branch HEAD equals the deployed commit.
This matters most for `apply-pending-tenant-flyway.sh --env prd`, whose pending set comes from the
checkout's migration files: a checkout that leads over-reports (safe), one that lags **under**-reports
silently. Note the prd endpoint reports `"environment":"dev"` — that is a mislabel, not a wrong host.
Related: [[wms2-actuator-info-build-time-identifies-the-deploy]], [[derive-cross-repo-claims-from-origin-develop]].
