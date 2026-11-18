---
name: hub-wms-ui
description: Vue/Nuxt and React UI traps, credentials, recipes. Hub: one line per member memory
metadata:
  type: reference
---

Hub for **WMS/OMS UI (web, mobile, siteboss-frontend)**. Moved out of MEMORY.md on 2026-10-28 to keep the index under its load limit; each line links the member memory (newest last).

- [SBDEV-2930 mobile per-page Vuex reset](sbdev-2930-mobile-page-reset-and-picking-timer-landmine.md) — LANDMINE: clearing `picking.timer` can kill
- [`:key` remount ≠ child state reset](vue-key-remount-does-not-reset-state-read-from-stale-parent-data.md) — clear the parent's arrays too
- [wms2-web-ui .gitignore `reports/` hides 34 files from grep](wms2-web-ui-gitignore-reports-hides-34-files-from-grep.md) — use `git grep`, not
- [Headless-browser recipe for wms2-web-ui dev](wms2-web-ui-headless-browser-recipe.md) — puppeteer-core outside the repo; the only route to a visual
- [Dev UI test login = panderson / dev@sb](wms2-dev-ui-test-credential-panderson.md) — Nam 2026-10-14; DEV + UAT (2026-10-31), never PRD; HAS warehouse access, fake the claim for no-access paths
- [Mount-with-value-present is not a reactivity test](vue-mount-with-value-present-does-not-test-reactivity.md) — a data() snapshot passed 8/8 while
- [wms2 UI OpenObserve RUM rollout](wms2-ui-openobserve-rum-rollout.md) — SDK has `clearUser` NOT `removeUser`; `trackAnonymousUser` defaults TRUE; +81KB gz even when off
- [v2 UI Dockerfiles never read the lockfile](wms2-ui-dockerfile-never-reads-the-lockfile.md) — RESOLVED in both repos (web-ui SBDEV-4079, PR 207); a deps change must commit yarn.lock, builds use --frozen-lockfile
- [OMS v2 UI is v2/siteboss-frontend; QA Manager = apps/qa](qa-station-v1-vs-v2-repo-map.md) — omsv2-UI is a Lovable prototype; v1/qa-* is OMS v1 only
- [wms2-mobile-ui apiError.js DOES render ProblemDetail detail](wms2-mobile-ui-apierror-renders-problemdetail.md) — 3 wms2-api javadocs say it does not exist; they are wrong (stale checkout)
- [Mobile $kc.logout() never ends the SSO session](wms2-mobile-kc-facade-logout-never-ends-sso.md) — façade nulls the instance first → always a reload; check-sso re-signs; Logout button too (SBDEV-3518)
- [Papa dynamicTyping → numbers](papa-dynamictyping-makes-csv-cells-numbers.md)
- Tests that can't see it: [Controllers need /v3 prefix; standaloneSetup blind](wms2-controller-mappings-must-carry-v3-standalonesetup-cannot-see-it.md) · [web-ui coverage disarms render-source pins](wms2-web-ui-coverage-instrumentation-disarms-render-source-pins.md)
- [Layout resets a section's list state on leaving it](wms2-web-ui-layout-resets-section-list-state.md) — "revisit keeps page" tests must stay in-section or reload
- [siteboss-frontend Cypress run recipe](siteboss-frontend-cypress-run-recipe.md) — 15.21.1 __dirname crash → use 15.15.0 binary; verify once cold; List.cy SBDEV-3115 red on main; apps/qa baseline 37 fails (11-09); no parallel runs
