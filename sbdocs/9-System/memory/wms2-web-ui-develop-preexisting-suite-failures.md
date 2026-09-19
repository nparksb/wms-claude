---
name: wms2-web-ui-develop-preexisting-suite-failures
description: wms2-web-ui develop is FULLY green (768/768, 64/64 suites) — the "2 always-red suites" was a STALE node_modules, not a repo condition
metadata:
  type: project
---

**CORRECTED 2026-08-27.** Earlier notes recorded "2 always-red Jest suites, 0 failing tests" on
`wms2-web-ui` develop. That was wrong about the cause, and the conclusion mattered: it made a red
suite look like the accepted baseline.

Measured on `origin/develop` while doing SBDEV-3012:

- With a **complete** `node_modules`: **64 / 64 suites, 768 / 768 tests, zero failures.**
  (768 includes 8 tests added by SBDEV-3012; the develop baseline is **760**.)
- With a **stale** `node_modules`: 2 suites fail to run —
  `test/components/admin/labelPrinting/labelCsvUpload.spec.js` (`Cannot find module 'exceljs'`) and
  `test/components/admin/labelPrinting/zplPreview.spec.js`
  (`Cannot find module 'zpl-renderer-js/dist/index.external.esm.js'`). Those 2 suites hold 22 tests.

**Both packages ARE declared in `package.json`** (`exceljs ^4.4.0`, `zpl-renderer-js ^4.0.0`). They
are simply missing from the long-lived `node_modules` in the main checkout, which predates them.
So the failure is an **install gap, not a code or test defect**, and "Test suite failed to run" is
the tell — a genuine failure reports failing *tests*.

⚠️ **The trap this creates.** Symlinking the main checkout's `node_modules` into a fresh worktree
(`ln -s ../../v2/wms2-web-ui/node_modules`) is the fast way to get Jest running, and it silently
inherits the gap — so a clean branch shows "2 failed suites" and it reads as the known baseline.
Fix: build a symlink FARM and overlay the missing packages, leaving the shared tree untouched:

```bash
rm node_modules && mkdir node_modules
cp -rs /home/nampark/dev/wms-claude/v2/wms2-web-ui/node_modules/. node_modules/
npm install --no-save --no-audit --no-fund exceljs@^4.4.0 zpl-renderer-js@^4.0.0
```

`yarn` is NOT on PATH; use an nvm node plus `node_modules/.bin/jest`. Prefer `--coverage=false` for
targeted runs — see [[wms2-web-ui-coverage-instrumentation-disarms-render-source-pins]].

**Treat any red suite here as a real signal now.** See also
[[run-wms2-mobile-ui-jest-tests]] (mobile has 19 suites / 226 tests, all green) and
[[wms2-develop-preexisting-test-failures]] for the Java side.
