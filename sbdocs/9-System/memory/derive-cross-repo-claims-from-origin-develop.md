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

## 2026-09-23, SBDEV-3418: the same rule broken a different way — a false ABSENCE

Every example above is *stale content read as current*: a wrong line, a wrong verb. Today's was
worse in kind. I ran a filesystem **`find`** over `v2/wms2-mobile-ui` for `apiError.js`, got nothing,
and concluded the file **"does not exist anywhere in that repo."** It exists on `origin/develop`,
`origin/main` and `origin/release` — added 2026-08-28, seven weeks before I looked. The checkout was
**77 commits behind** (it was 26 when this memory was written; staleness grows while you are not
watching).

**Why a false absence is the dangerous case.** A stale line number produces a wrong citation. A false
absence produces *licence to delete someone else's correct statement*. Two `src/main` javadocs already
carried the true claim; on the strength of that `find` I overwrote both with the falsehood — and
labelled it **"Measured, not assumed"**, because running a command feels like measuring. Three files
ended up asserting the opposite of the truth, and it took an independent lane to catch it.

Two compounding factors worth naming:

- **`find` and `ls` have no ref.** `git grep`/`git show` at least *can* take one; a filesystem walk
  cannot, so there is no version of it that is safe for a cross-repo claim. Reach for
  `git show origin/develop:<path>` even when you are only asking "does this file exist?".
- **The zero agreed with me.** I was checking whether my own claim held, and absence confirmed it —
  which is exactly when [[a-zero-scan-needs-a-positive-control]] applies and exactly when it is least
  likely to be applied. The positive control here was one command:
  `git -C <repo> rev-list --count HEAD..origin/develop`.

**So, sharpened:** *before asserting a file, symbol or behaviour is ABSENT from another repo, print the
lag first.* If the count is non-zero, a filesystem-derived absence is not evidence of anything.

Related: [[plan-state-probe-beats-reading-plan-status]] (same family: derive state, do not read it),
[[wms2-web-ui-gitignore-reports-hides-34-files-from-grep]], [[lane-a-git-cherry-false-positives]].
