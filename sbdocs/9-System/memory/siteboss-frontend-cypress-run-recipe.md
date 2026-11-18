---
name: siteboss-frontend-cypress-run-recipe
description: Running siteboss-frontend Cypress component specs headless — Cypress 15.21.1 dies on vite.config __dirname; use the cached 15.15.0 binary; first verify times out cold
metadata:
  type: reference
---

Measured 2026-11-04 (SBDEV-3118), on the Mac, in a fresh worktree off `origin/main`:

- `npm ci` in the worktree takes about 2 minutes; the main checkout has no `node_modules` either.
- **Cypress 15.21.1** (what `^15.7.1` resolves to now) fails before any spec runs:
  `ReferenceError: __dirname is not defined at apps/owl/vite.config.js:20`. The package is
  `"type": "module"` and 15.21.1's vite-dev-server loads the config raw. This is an environment
  failure, not a test failure.
- Workaround: `CYPRESS_RUN_BINARY=~/Library/Caches/Cypress/15.15.0/Cypress.app/Contents/MacOS/Cypress npx cypress run --component --browser electron --spec <spec>`.
- **The first `verify` of any cached binary times out** ("Cypress verification timed out"). Run
  `npx cypress verify` (with the same `CYPRESS_RUN_BINARY`) once, then the run works.
- Baseline on main `6a0cf9fbe`: in `apps/qa/.../Exceptions/List/List.cy.jsx`, "drops the dispatched
  rows as soon as the regenerate is accepted" (SBDEV-3115) is red **3/3 runs**, and a second test
  flaked once. Compare per test, not totals.
- FakeApp wraps every mount in the owl `PermissionProvider autoLoad`, so a spec controls permissions
  by intercepting `GET **/auth/user*` → `{data:{permissions:[{module_id, permission_level}]}}`.
  Specs that don't intercept it render with `permissions = null`, so `hasPermission` is false for
  every module.

Measured 2026-11-09 (SBDEV-2992), main `b934c4bb2`:
- **Full `apps/qa` component baseline: 37 failures across 12 of 22 specs** (FailItems, useQaRealtime,
  Returns, Reprint, Parcel*, ParcelList, ParcelInfo, UserPreferencesDrawer, qaItemName, Exceptions/List).
  ~5 min. Diff failing test NAMES branch vs base, never totals: each run also flakes one random test.
- Never run two Cypress runs at once, and never edit sources under a running suite (Vite hot-reloads
  them mid-run): both produced uninterpretable reds. Stopping the task leaves Cypress.app processes alive.
- zsh traps in these loops: `$b:apps/...` is parsed as the `:a` modifier (use `${b}:`), `$F` does
  not word-split, arrays are 1-indexed.
