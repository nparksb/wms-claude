---
name: derive-cross-repo-claims-from-origin-develop
description: Sub-repo checkouts here lag by unknown amounts (oms-laravel-api by 838 commits) — grep origin/develop after a fetch, never the working tree; omsv2-UI has no develop branch at all
metadata:
  type: feedback
---

Measured 2026-08-28 on SBDEV-3157, across every sub-repo. **Nearly all working checkouts lag
`origin/develop`**, one catastrophically — and one repo is not on `develop` at all:

| repo | branch | behind |
|---|---|---|
| `v2/oms-laravel-api` | develop | **838** |
| `v2/wms2-mobile-ui` | develop | 26 |
| `v2/wms2-web-ui` | develop | 19 |
| `v2/wms2-api` | develop | 9 |
| `v1/wms-api` | develop | 8 |
| `v1/wms-mobile-ui` | develop | 3 |
| `v1/wms-web-ui` | develop | 0 |
| `v2/omsv2-UI` | **`Loveable-Dev`** | 1 behind `origin/main` — **no `develop` branch exists**, so a `origin/develop` grep here errors rather than returning nothing |

⚠ Do not shorten this to "every checkout is stale": `v1/wms-web-ui` was at 0, and a rule stated as an
absolute gets discarded the first time someone finds the counterexample. The point is that staleness is
**unknown until measured**, not that it is universal. Measure with
`git -C <repo> rev-list --count HEAD..origin/develop` after a fetch.

**What it cost.** A review lane found that OMS writes over SDR (`PATCH /v3/client/{id}`). I rejected the
finding with a five-row evidence table. **Every row was true of the working checkout and false of
`origin/develop`:**

| my claim | stale HEAD | `origin/develop` |
|---|---|---|
| `config/wms.php:86` = `'rest/client/update'` | true | it is `:104`, `'v3/client/{id}'` |
| called with `'PUT'` at `:2978` | true | `:3281`, `'PATCH'` |
| zero `'PATCH'` in `WmsApiService` | true | 2 hits |

**How to apply.**

1. **Any claim about another repo's code must be read at `origin/develop` after `git fetch`** — e.g.
   `git show origin/develop:config/wms.php`, or `git grep <pat> origin/develop -- <paths>`. `git grep` with
   a ref also sidesteps the ignore-aware-wrapper trap in `wms2-web-ui` (its `.gitignore` has a bare
   `reports/`), so it fixes two problems at once.
2. **A line-number disagreement is the tell.** If two readings of "the same" file cite different lines for
   one symbol (`:86` vs `:104`), one of them is on a different commit. Check the ref before arguing.
3. **A rejection needs MORE provenance discipline than a claim**, not less — it stops someone else
   looking. I have now twice rejected a correct review finding using a stale or wrong-axis source; both
   times the reviewer was right.
4. `wms-triage`'s probe question 1 already says *"do not trust a local checkout"*. I applied it to two
   repos and not to the third in the same session, which is how it slipped.

Related: [[plan-state-probe-beats-reading-plan-status]] (same family: derive state, do not read it),
[[wms2-web-ui-gitignore-reports-hides-34-files-from-grep]], [[lane-a-git-cherry-false-positives]].
