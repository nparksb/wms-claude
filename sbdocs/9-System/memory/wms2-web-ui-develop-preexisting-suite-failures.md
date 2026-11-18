---
name: wms2-web-ui-develop-preexisting-suite-failures
description: "wms2-web-ui develop is FULLY green (768/768, 64/64 suites) — the \"2 always-red suites\" was a STALE node_modules, not a repo condition"
metadata:
  node_type: memory
  type: project
  originSessionId: 73044a3b-94bc-4eac-81f7-0e33353ba62c
  modified: 2026-10-29T02:30:42.264Z
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

**Update 2026-10-29 (SBDEV-3591, on the Mac):** the gap has grown to **4 packages and 5 suites**. The
missing packages are `exceljs`, `zpl-renderer-js`, `@openobserve/browser-rum` and `@openobserve/browser-logs`.
The 5 suites that fail to load are `labelCsvUpload`, `zplPreview`, `telemetry`, `keycloak-ready` and
`keycloak-logout-clears-state`. `telemetry.js` imports browser-logs too, so installing only browser-rum is not
enough. With all 4 present, develop+branch went 143/143 suites, 2533/2533 tests. BSD `cp` has no `-s`, so on the
Mac, build the farm and keep npm away from the shared tree:

```bash
X=<scratchpad>/webui-missing-deps; mkdir -p $X && cd $X && echo '{"name":"overlay","private":true}' > package.json
npm install --no-audit --no-fund --ignore-scripts exceljs@^4.4.0 zpl-renderer-js@^4.0.0 @openobserve/browser-rum@0.4.1 @openobserve/browser-logs@0.4.1
cd <worktree>; M=<main checkout>/node_modules; rm node_modules; mkdir node_modules
for e in "$M"/* "$M"/.[!.]*; do [ -e "$e" ] && ln -s "$e" "node_modules/$(basename "$e")"; done
ln -s $X/node_modules/exceljs $X/node_modules/zpl-renderer-js $X/node_modules/@openobserve node_modules/
```

⚠ **wms2-web-ui CI runs NO Jest** (its "Docker Image CI" only builds). A suite that does not load locally is graded
by nobody. Never write "CI will catch it" in a web-ui PR. SBDEV-3591 did that and had to correct it.

**Treat any red suite here as a real signal now.** See also
[[run-wms2-mobile-ui-jest-tests]] (mobile has 19 suites / 226 tests, all green) and
[[wms2-develop-preexisting-test-failures]] for the Java side.

**Update 2026-10-29 (SBDEV-3949, Mac):** with the 4-package overlay, develop is green EXCEPT one load-flaky test:
`test/store/reports/returnsAudit.spec.js` › *SBDEV-3769 export — pages through until totalElements…* failed in 3 of 6
full runs (develop and branch alike) and passes 3/3 alone. Rerun before reading it as a regression. Also:
the Mac's nvm default is **Node 8.12** (Jest 27 cannot run on it) — use `~/.nvm/versions/node/v18.20.5/bin`.
macOS has no `timeout` command, so `timeout N jest …` exits 127, not a hang.
