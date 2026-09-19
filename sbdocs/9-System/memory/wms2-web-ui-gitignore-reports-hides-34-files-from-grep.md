---
name: wms2-web-ui-gitignore-reports-hides-34-files-from-grep
description: A bare `reports/` in wms2-web-ui/.gitignore makes every ignore-aware search tool skip store/reports, components/reports and pages/reports — 34 tracked, shipped files. Use `command grep` for caller inventories.
metadata:
  type: reference
---

`v2/wms2-web-ui/.gitignore:106` is a bare **`reports/`** (added for `cypress/reports`). Gitignore semantics
match that against **any directory named `reports` at any depth**, so it swallows three real source trees:

- `wms2-web-ui/store/reports/` (10 files)
- `wms2-web-ui/components/reports/` (14 files)
- `wms2-web-ui/pages/reports/` (10 files)

All 34 are tracked and shipped — `git ls-files store/reports components/reports pages/reports` lists them,
because git honours the index over the pattern. But **every ignore-aware search tool silently skips them**:
ripgrep, ugrep, Claude Code's `Grep` tool, and — the trap — the `grep` **shell function** in this environment,
which wraps `ugrep -G --ignore-files`. Measured 2026-08-24:

```
$ grep -rn "exportFlowbin" .          # ugrep wrapper -> rc=0, NO OUTPUT
$ command grep -rn "exportFlowbin" .  # GNU grep      -> store/reports/flowbin.js:87
```

**Why:** this produces false "0 callers / dead endpoint" conclusions, and one nearly shipped. On SBDEV-3017
slice B a lane reported `POST /v3/billOfLading/palletize` as dead surface and recommended **deleting** it; GNU
grep found a live caller at `store/reports/outboundParcel.js:129` (Outbound Parcel Report screen). Another lane
independently concluded "9 of 11 ReportController endpoints are dead" — all 11 have live callers. Deleting or
mis-gating on that basis breaks the Reports screens, and there is no menu gating in that repo to hide the
failure: the button stays enabled and 403s with a generic "network or server issue" toast
([[verify-script-traps]] is the same class of blind measurement).

**How to apply:**
- **Best tool: `git grep -n <pattern> origin/develop`.** It greps *tracked files in the named revision*, so it
  sidesteps BOTH traps at once — the `.gitignore` pattern and a stale working tree — and needs no `--exclude-dir`.
  Verified 2026-08-24: wrapped `grep` 0 hits, `command grep` 1 hit, `git grep origin/develop` 1 hit. (Credit: a
  peer session's correction; my original advice below only fixed half the problem.)
- Failing that, `command grep -rn --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=coverage`. Never
  the bare `grep` function, never the `Grep` tool.
- Treat any "0 callers" result as **unproven** until re-run with GNU grep — most of all for Reports screens.
- Also exclude `coverage/lcov-report/`, which contains HTML copies of every component and inflates counts.
- Search for the endpoint **path** (`'/billOfLading/palletize'`), not the bare method name: name-only greps hit
  Vuex mutations with the same identifier (`setPallet`, `setSection`) and manufacture false positives in the
  other direction.
- **`git grep -n <pattern> origin/develop -- '*.vue' '*.js'` beats `command grep` and solves a SECOND trap at
  the same time.** It greps tracked files **in the named revision**, so it ignores both `.gitignore` *and* the
  working tree. That matters because local UI checkouts are routinely stale: measured 2026-08-24,
  `wms2-web-ui` was **12** commits behind `origin/develop` and `wms2-mobile-ui` **18**. A `command grep` over a
  stale tree is ignore-safe but still wrong. On SBDEV-3071 this understated the `getAllRoles`/`isWmsUser`
  caller inventory as **3 sites when develop has 6** (missing `store/index.js:218` and
  `store/home.js:182`) — the verdict survived, the inventory did not. A peer session lost a whole ticket
  (SBDEV-3078, closed invalid) to the stale-tree half of this.
- Related, same repo: [[wms2-web-ui-develop-preexisting-suite-failures]].
