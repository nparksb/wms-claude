# SBDEV-3418 — review of the withdrawal commit `cca3aaf3`

**Scope**: the single comment-only commit `cca3aaf3` ("withdraw a false cross-repo claim I introduced
in ed2ed97a"), on `bugfix/SBDEV-3418-truck-loading-transaction-boundary`, PR #397 in `v2/wms2-api`.
Reviewed 2026-09-23. Worktree `.claude/worktrees/wms2-api/SBDEV-3418`, HEAD `cca3aaf3`.

**Verdict: APPROVE WITH NITS. PR #397 is safe to merge.**

Every substantive claim the commit restores was independently re-derived from `origin/develop` of
`wms2-mobile-ui` and is **true**. The lock-set recipe runs as written. Nothing in `src/main` or
`src/test` still asserts the withdrawn premise. The one finding that touches the commit's own purpose
(F1) is a botched text splice in the paragraph it exists to restore — cosmetic, but free to fix and
worth fixing before merge because it is evidence the restored paragraph was not re-read.

---

## Summary table

| # | Severity | File | Finding |
|---|---|---|---|
| F1 | **Medium** | `MobilePalletizingService.java:224-228` | The restored D2 paragraph carries the **same sentence twice**, and the inserted ⚠ correction strands the "Translated, …" half of the contrast inside it. Splice artifact in the exact paragraph being restored. |
| F2 | Low | `MobilePalletizeWriteService.java:325-326` + commit message | "toastApiError is called from the catch of **every** store action" — an unqualified completeness claim that is not literally true. The conclusion it supports *is* true. |
| F3 | Low | `sbdocs/…/SBDEV-3418-evidence/rereview-fix-commits.md:234` | A superseded evidence file still asserts the withdrawn premise with no retraction marker. Outside `src/`, so outside the stated review scope, but it is the sibling-copy pattern that spread the original defect. |
| F4 | Nit | commit message | "Verified: 73/73 across the **four** affected unit classes" names no class and is not reproducible as stated. Immaterial. |

No High findings. No correctness, security, or build risk.

---

## 1. Are the restored statements actually TRUE?

All verified against `origin/develop` of `v2/wms2-mobile-ui` (fetched fresh; `git show`/`git ls-tree`
against the remote ref, never the working copy).

| Claim as restored | Verdict | Evidence |
|---|---|---|
| `util/apiError.js` exists on `origin/develop`, `origin/main`, `origin/release` | **TRUE** | `git ls-tree` returns the *same* blob `e8ee88e6` on all three refs. |
| Added 2026-08-28 by `3174486b`, "surface the backend's error message instead of a fixed generic red bar" | **TRUE** | `3174486 2026-08-28 fix(errors): surface the backend's error message instead of a fixed generic red bar`; its `--stat` adds `util/apiError.js` (79 lines) and `test/util/apiError.spec.js`. Subject quoted verbatim and correctly. |
| `apiErrorMessage` prefers the ProblemDetail `detail` | **TRUE** | Preference order #1 in the source: `if (typeof data.detail === 'string' && data.detail.trim()) { return data.detail }`. |
| `store/truckLoading.js` `scanGate`'s catch calls `toastApiError` | **TRUE** | `scanGate` at line 117; its catch is `} catch(error) { console.log(error), toastApiError(this.$toast, error) hasError = true }`. |
| `plugins/axios.js` `onError` intercepts only `403 && body.reason` | **TRUE** | The only status-conditional branch is `if (status === 403 && body.reason)`; the hook ends `return Promise.reject(error)` unconditionally, so a 409 rejects straight through to the store catch. |

### The palletize store — checked separately, as instructed

The prior round was burned generalising one endpoint's behaviour. It does **not** bite here: the
claim holds for palletize independently, not by inheritance.

`origin/develop:store/palletizing.js` has exactly four catch blocks, and **all four** are
`toastApiError(this.$toast, error)` — `scanParcel`, `scanPallet`, `rapidScanPallet`,
`rapidScanParcel` (lines 57-60, 77-80, 97-100, 119-122). The restored text is correct for the
palletize javadocs as well as the truck-loading one.

### Root cause claim

`v2/wms2-mobile-ui` local HEAD is `aa3a4dd` (2026-07-28); `origin/develop` is `5b1d336` (2026-09-16).
`git rev-list --count HEAD..origin/develop` = **77**, exactly as the commit message states, and
`git ls-tree HEAD -- util/apiError.js` is genuinely **empty** — so the stated mechanism for the false
zero is confirmed, not merely plausible.

> ⚠ Method note for the next reader: my own first presence check reported ABSENT on all three
> branches. That was my instrument, not the repo — in zsh, `$b:util/...` applies the `:u`
> history modifier and uppercases `$b`, yielding `ORIGIN/DEVELOPtil/apiError.js`. Only the negative
> control caught it. Use `git ls-tree "$ref" -- <path>` or `${b}:path`.

---

## 2. Is the restoration faithful?

**`MobilePalletizeWriteService` — faithful. ✅** `origin/develop` lines 312-313 read
"`only receives genuinely unmapped exceptions. The handheld renders that detail as a toast
(wms2-mobile-ui util/apiError.js).`" The restored text at 320-321 is that sentence **verbatim**,
followed by a bounded ⚠ note. No third version invented.

**`MobilePalletizingService` — calibration genuinely back, text botched. ⚠ (F1)** The D2 wording
`origin/develop` carried — "That is a UX-consistency improvement, **not** a rescue from an unhandled
failure. Plan §3.6 (D2) asks for it on those terms; it is not load-bearing for correctness." — is
restored, and the inflated "the difference between a named, actionable message and a generic network
error" now appears only inside a parenthetical that explicitly withdraws it. The calibration the task
asked about is **correctly** back. But the splice left a duplicate:

```java
     * improvement, <b>not</b> a rescue from an unhandled failure. Plan §3.6 (D2) asks for it on   // 224
     * those terms; it is not load-bearing for correctness. (SBDEV-3418 also inflated this paragraph // 225
     * on the strength of the false premise above — "the difference between a named, actionable      // 226
     * message and a generic network error" — and that inflation is withdrawn with it.) Plan §3.6 (D2) asks for it on those  // 227
     * terms; it is not load-bearing for correctness.                                                // 228
```

"Plan §3.6 (D2) asks for it on those terms; it is not load-bearing for correctness." appears at
224-225 **and again** at 227-228. Line 227 is also 126 chars, against the file's ~100-char wrap.

Secondary readability regression in the same edit: the ⚠ correction paragraph was inserted at 215-220
*between* "Untranslated, the operator gets a 409 …" and "Translated, they get …", so the second half
of the contrast (line 221) is now stranded inside the correction paragraph instead of continuing the
sentence it answers.

**Fix**: delete lines 227-228 back to `…withdrawn with it.)`, and move the ⚠ paragraph to after the
Untranslated/Translated contrast completes. One-line deletion plus a paragraph move; no code risk.

---

## 3. The lock-set derivation recipe (`MobileTruckLoadingWriteService.java:120-129`)

**It works.** Run verbatim from the worktree root:

```
$ git grep -n "Repository\." -- src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java
exit=0   hits=50
```

Exactly the **50 hits** the commit message claims. The two prior faults are both gone:

- **Exit-2 fault — fixed.** The old form `grep -n "Repository\.\(find\|get\)" UnitloadBusinessService.java` still reproduces the failure (`exit=2`), and the javadoc now documents that trap explicitly rather than silently fixing it.
- **`*/` build-break — gone.** Proven lexically rather than by eye: I stripped all comments from each of the four files at `ed2ed97a` and at `cca3aaf3` and compared the resulting token streams. All four are **identical**. A stray `*/` would have leaked javadoc prose into the code stream and changed the hash, so this simultaneously proves (a) the commit is genuinely comment-only, as claimed, and (b) no javadoc block is prematurely terminated. `<b>`/`<i>` tags are balanced in all four files.

**The stated blind spot is accurate.** `WmsConstants.CODE_TRUCK_LOADING = "TRUCKLOADING"` is in
`PickLineActivityCodeClassifier.PASS_THROUGH_CODES`, **not** `BLOCK_REALIGN_CODES` (which holds only
`CODE_MOVE_FIX_ASSIGNMENT`, `CODE_MANUAL_TRANSFER`, `CODE_TRANSFER`, `CODE_ON_HOLD`). The
`lockOwningPickingorders` call sits behind
`if (PickLineActivityCodeClassifier.classify(activityCode, null) == Bucket.BLOCK_REALIGN)` at
`UnitloadBusinessService.java:235-238`, so truck loading never reaches it — and `pickLineRealignmentService.`
does not match `Repository\.`, so it would indeed be invisible to the recipe. Both halves check out.

---

## 4. Claims in the commit message itself

Checked as reviewable text, per the two-false-claims-in-two-commits history. **No falsehood found.**
The `77 commits`, the dates, the `3174486b` SHA and its subject line, the three-branch presence, the
`detail` preference, the `403 && body.reason` scope, the exit-2 recipe fault and the `*/` fault are
all independently confirmed above. Two imprecisions:

**F2 (Low)** — "`toastApiError` is called from the catch of **every** store action", repeated in
`MobilePalletizeWriteService.java:325-326`. Of 13 stores, 12 import `toastApiError`;
`store/cancellation.js` imports `apiErrorMessage` + `API_ERROR_TOAST_DURATION` instead and renders via
its own `toastError(this.$toast, context, apiErrorMessage(error, …))` wrapper. The *substantive*
claim — the operator sees the server's `detail` — holds there too, and holds exactly for `scanGate`
and all four palletize actions. So the conclusion is sound; only the universal quantifier is wrong.
Given this branch's history with completeness words, suggest "from the catch of every store action on
this screen and the palletize screen" or "from 12 of the 13 stores; the 13th renders the same `detail`
via `apiErrorMessage`".

**F4 (Nit)** — "Verified: 73/73 across the **four** affected unit classes." `MobilePalletizeWriteService`
has no `…UnitTest`; the unit classes named after the other three changed services sum to exactly 73
(`MobilePalletizingServiceUnitTest` 50 + `MobileTruckLoadingServiceUnitTest` 11 +
`MobileTruckLoadingWriteServiceUnitTest` 12), i.e. **three** classes, not four. A four-class reading
also reaches 73 (`MobilePalletizingServiceTest` 27 + `MobileTruckLoadingServiceTest` 21 +
`MobilePalletizeFirstTouchInvariantUnitTest` 13 + `MobileTruckLoadingWriteServiceUnitTest` 12), so the
number is not disproved — it is simply **not reproducible from the message**, which names no class.
Immaterial here: the commit is provably comment-only, so test outcomes are necessarily identical to
`ed2ed97a`'s. Name the classes next time.

---

## 5. Residual assertions of the withdrawn premise

Swept `src/` for eight phrasings of the old claim (`does not exist`, `no such file exists`,
`fixed network-error`, `network or server issue`, `does NOT render`, `Measured, not assumed`,
`generic network error`, `fixed string`).

**In `src/main` and `src/test`: no site still asserts it.** Every surviving occurrence of the
withdrawn wording is inside the withdrawal text, quoting the false claim in order to retract it
(`MobilePalletizeWriteService.java:324`, `MobileTruckLoadingService.java:230-232`,
`MobilePalletizingService.java:227`). The `"network or server issue"` hits in
`BillOfLadingController`, `CycleCountController`, `DestinationEligibilityService`,
`ScannedCodeResolver`, `StockunitService` and two tests are pre-existing, unrelated, and describe the
*pre-`apiError.js`* generic toast in their own tickets' context — not this claim.

**F3 (Low, outside `src/`)**: `sbdocs/1-Projects/wms2/plan/SBDEV-3418-evidence/rereview-fix-commits.md:234`
still reads "There is no `util/apiError.js` anywhere in …". That is the superseded report that
produced the defect. `final-commit-review.md` in the same directory refutes it, but a future reader
grepping the evidence directory hits both with nothing marking which won. Suggest a one-line
`> ⚠ SUPERSEDED — this finding was false; see final-commit-review.md` at the top of the stale file.

One unrelated cross-repo claim noted in passing and **not** a finding:
`Sbdev3017TrancheGateContextTest.java:613` ("Web-only is MEASURED, not assumed, on origin/develop of
both UIs") is pre-existing on `origin/develop` and untouched by this branch — out of scope, but it is
the same claim shape and may deserve its own re-derivation someday.

---

## 6. Other observations (not findings)

- The branch also deletes two lines from the ArchUnit freeze store
  `src/test/resources/archunit_store/5fb3fee0-…`, both `MobileTruckLoadingService.scanGate → Optional.get()`
  violations. That is a legitimate **tightening** (scanGate no longer calls `Optional.get()`), not a
  suppression.
- `MobilePalletizingService` and `MobilePalletizeWriteService` are **comment-only across the whole
  branch** — their comment-stripped token streams are identical to `origin/develop`. Their inclusion
  in this PR is documentation collateral, which is what made the `ed2ed97a` overwrite possible.

## 7. Method / limitations

- Claims re-derived from `origin/develop` via `git show`/`git ls-tree` on the remote ref; the stale
  local working copy was never read. Presence checks carried positive and negative controls.
- The recipe was executed, not read.
- Comment-only status proven by comment-stripped token-stream comparison, not by reading the diff.
- **Not run**: no Maven. A sibling `mvn clean verify` was live in `.claude/worktrees/wms2-api/SBDEV-3458-run`
  against the shared Testcontainers postgres for the whole review window, and the task forbade
  competing with it. The 73/73 claim is therefore **not** re-executed here. It is immaterial: the
  commit is provably comment-only, so its test outcomes are identical to `ed2ed97a`'s by construction.
  If an independent green is wanted, run `mvn -o test -Dtest=MobilePalletizingServiceUnitTest+MobileTruckLoadingServiceUnitTest+MobileTruckLoadingWriteServiceUnitTest`
  once the sibling clears (note: `+`, not `,` — a no-match selector leaves stale surefire XML).
