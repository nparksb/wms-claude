---
name: run-wms2-mobile-ui-jest-tests
description: "wms2-mobile-ui has a working Jest suite; how to run it. The CLAUDE.md that denied this was FIXED 2026-08-27 — a stale local checkout is now the only place that claim survives"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 01501a1c-d69a-4474-9e21-c8aed94b2607
  modified: 2026-09-15T16:52:06.783Z
---

`v2/wms2-mobile-ui` **does** have a configured Jest suite.

⚠️ **CORRECTED 2026-08-28 — the "CLAUDE.md says otherwise" half of this memory has EXPIRED.** That file
was fixed on `origin/develop` on **2026-08-27 under SBDEV-3012**; it now says *"There IS a Jest suite"*
and names the config, the script and the suite count. **Do not report it as stale.** I did on
2026-08-28 and was wrong: I had read the main checkout, which was **26 commits behind** `origin/develop`.
Read `git show origin/develop:CLAUDE.md`, never the working copy — this is the same
local-checkout trap the triage probe's question 1 exists to catch, and a memory saying "that doc is
wrong" makes you *more* likely to fall into it, not less.

- `jest.config.js` exists: `roots: ['<rootDir>/test']`, `moduleNameMapper` maps `^~/(.*)$` and `^@/(.*)$` → `<rootDir>/$1`, `testEnvironment: 'jsdom'`, transforms via `babel-jest` + `vue-jest`.
- `package.json` has `"test": "jest"` and `@vue/test-utils` + `vue-jest` + `babel-jest`.
- Specs live under `test/` (e.g. `test/plugins/*.spec.js`, `test/util/*.spec.js`). Import app modules via the `~/` alias, e.g. `import { foo } from '~/util/replenishMessages'`.

**Run (no `yarn` on PATH — same as [[run-v1-wms-web-ui-jest-tests]]):**
```bash
cd v2/wms2-mobile-ui
export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh" && nvm use node
node_modules/.bin/jest --testPathPattern=<name>
```
Suite size moves with every merge — **measure it, do not quote it**. Two dated readings, both all-green:
`f42ac8d` (2026-08-28) = 20 spec files / 233 tests; `ab1e2ae` (2026-09-15) = **32 suites / 395 tests**,
~5 s. Specs live across `test/{components,middleware,pages,plugins,store,util}`; there are also 7 Playwright
`*.spec.ts` files under `tests/e2e/`, which `jest.config.js` deliberately excludes via `roots`.
A worktree has no `node_modules` — symlink the main checkout's before running.
Confirmed working on node v24.15.0 (2026-07-19, SBDEV-2070 helper unit test). Prefer pure helper modules under `util/` for unit-testable UI logic (Vue templates call them via a thin method wrapper).
