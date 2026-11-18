---
name: wms2-web-ui-returnsaudit-export-test-timing-flaky
description: "wms2-web-ui returnsAudit.spec.js \"SBDEV-3769 export … pages through\" times out (5000 ms) in ~half of full Jest runs, on clean develop too; passes alone. Rerun before debugging"
metadata:
  node_type: memory
  type: project
  originSessionId: 73044a3b-94bc-4eac-81f7-0e33353ba62c
  modified: 2026-10-29T02:30:48.855Z
---

`test/store/reports/returnsAudit.spec.js` has a case, *"SBDEV-3769 export — CSV over every page of the filtered
window › pages through until totalElements is reached and downloads one CSV with every row"*, that intermittently
fails with `Exceeded timeout of 5000 ms for a test`. It only happens under full-suite parallel load.

Measured 2026-10-29 during SBDEV-3591:
- **clean `origin/develop` aec32d0, 3 full runs:** failed 2 times;
- **branch, 4 full runs:** failed 2 times;
- **run alone:** 58/58, 3 times out of 3;
- **branch with complete node_modules, 2 runs:** passed both times.

It imports nothing a typical report change touches (`store/reports/returnsAudit`, `util/returnsAudit`,
`util/apiError`, `util/latestRequest`, `plugins/persistedState.client`).

**Why:** this red looks exactly like a regression on whatever branch is being graded. Treated as a real failure,
it costs a develop-baseline investigation each time.

**How to apply:** if it is the only red, run the spec alone and rerun the full suite before investigating. If it
fails alone, or fails with a different message, it is real. Not yet ticketed. A fix would raise that case's timeout
or fake the export pacing timers (`EXPORT_MIN_PAGE_MS = 10000` in the store).

Related: [[wms2-web-ui-develop-preexisting-suite-failures]].
