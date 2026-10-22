---
name: sibling-merge-silently-disarms-your-tests
description: A PR's green check grades the base it ran on; after a sibling merges, a new branch conjunct on a @Mock answers false and silently reroutes your tests away from the branch they grade
metadata:
  type: feedback
---

**A green PR check is a statement about the base it ran on, not about what will land.**
Measured 2026-09-14 on wms2-api #355/#356: #356's check was green on `d80b5083`; #355 merged 20
minutes later touching four of the same files, and on the real merge **six of #356's own tests
failed**.

**The mechanism, which generalizes:** #355 added a fourth conjunct to a branch
(`&& unitloadService.restsInStorageLocation(...)`). The sibling PR's fixture stubbed the other three.
`unitloadService` is a `@Mock`, so the new call answered **`false`** — every test fell through to the
*other* arm and died on an unrelated NPE.

⚠ **The dangerous direction is the quiet one.** Those tests died only because the other arm happened
to be unstubbed. Had it been stubbed, they would have gone **green while no longer touching the
branch they exist to grade** — see [[green-tests-that-prove-nothing]]. A new conjunct on a mocked
collaborator disarms every sibling fixture that does not know about it.

**Why:** Mockito's default answer for an unstubbed `boolean` is `false`, so adding a conjunct is a
silent behaviour change in every test that reaches that branch — no compile error, no stub-mismatch,
nothing STRICT_STUBS flags (an *unused* stub is flagged; a *missing* one is not).

**How to apply:**
- After any sibling merge touching your files, **re-run the suite on the actual merge**, never trust
  the PR's existing check. `mergeStateStatus: CLEAN` means no textual conflict — it says nothing
  about semantics.
- When you add a conjunct to a branch condition, grep for every test class that drives that method
  and stub it there too. The author of #355 did stub it — but only in *its own* nested class, 130
  lines above the sibling class that needed it.
- Commit before running the suite you intend to quote. A green run against an uncommitted working
  tree proves nothing about what you push — this cost a red CI cycle in the same session.

Related: [[wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway]] (a red develop silently stops
deploying, so merging on a stale green is not self-correcting), [[mvn-without-clean-runs-deleted-tests]].

**Second mechanism, measured 2026-10-15 (merging #510/#513/#518/#519 in sequence): STRUCTURAL rails break on a
clean-looking merge.** Three reds, none of them a textual conflict, each caught only by the full `-Pci` suite on the
real merge:
- `ReplenHoldPolicyCallerArchTest` keys decided callers by `Class.method/ARITY`. One side added a parameter to the
  helper (`/6` → `/7`), and the other side's allow-list went red. Same caller, same decision; only the key moved.
- `NoBareTransferNeverRailTest` (added by one PR) flagged a bare `never().transferStockToUnitLoad(...)` that a
  *third* PR (SBDEV-3758) had added in parallel. Neither PR could see the other.
- `NeverMatcherNullBlindnessArchTest`'s per-class inventory moved in both directions. Note: an entry at `:0` is
  treated as stale, so the entry must be **deleted** (leave a one-line removal note), not set to 0.
Also: a signature change on one side (an added parameter) compiles-breaks the OTHER side's new tests that call the
old arity. That's loud, but it only shows up after the merge.
**How to apply:** after merging develop into a PR branch, run the full suite before pushing, and treat any
arch/inventory red as "re-derive the key from the measured value". Never hand-edit the count from arithmetic; set
it to what the test reports, after reading the signature.
