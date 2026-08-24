---
title: "SBDEV-3003 Slice 1 — review lane: wms2-mobile-ui Fix D (in-flight guard)"
ticket: "SBDEV-3003"
type: review
lane: mobile
version: v2
reviewed_commit: "20d697d (pre-review 931e38e, amended away)"
base: "origin/develop 7f83d55"
created: 2026-08-20
updated: 2026-08-20
related:
  - ../SBDEV-3003-move-stock-lost-update-inventory-inflation.md
  - ./SBDEV-3003-review-api-verify.md
  - ../SBDEV-2994-move-stock-unknown-destination-container-generic-error.md
tags: [review, wms2, slice1]
---

# Review lane — `wms2-mobile-ui` Fix D

> **Provenance.** This is a **consolidated record**, written 2026-08-20 *after* the lane ran, from the
> artifacts the lane left behind: plan §9.1's Review row, commit `20d697d`'s message, and the
> annotations the lane's findings put into `scanDestination.vue` and
> `test/components/move-stock-double-submit.spec.js`. The lane's verbatim transcript was **not**
> persisted at the time — unlike SBDEV-2994/2995, whose reviews in this folder are raw lane output.
> Every measurement below is quoted from those durable artifacts; nothing is re-derived here. Where
> the original finding text is unrecoverable, the row says so instead of paraphrasing a guess.
> **Persisting the transcript is the process fix; this file is the retrofit.**

**Verdict: behaviour correct. Ship.** No interleaving admits a second transfer dispatch.

---

## 1. What was reviewed

| | |
|---|---|
| Commit | **`20d697d`** — `fix(move-stock): SBDEV-3003 guard the transfer dispatch against a double submit` |
| Base | `origin/develop` **`7f83d55`** |
| Diff | `components/moveStock/scanDestination.vue` +36/−4 · `components/moveStock/inputAmount.vue` +13/−1 · `test/components/move-stock-double-submit.spec.js` +377 |
| Tier | **T1** per plan §3.0 (one screen pair, reversible, no contract change) |

---

## 2. Correctness — how it was established

The lane did **not** accept the guard on reading. It built **nine mutants**, including the one that
matters most:

> **a control that reverts only the SBDEV-3003 guard while leaving SBDEV-2994's probe guard intact.**

That control is the whole discrimination problem of this ticket. `scanDestination.vue` already had a
`submitting` flag before this change (SBDEV-2994), raised immediately before
`await dispatch('checkContainer')` and dropped in that try's `finally` — **well before** the transfer
is dispatched. So the file *looks* guarded on inspection, and a test or verify row that cannot
separate "the probe is guarded" from "the transfer is guarded" certifies nothing. The control mutant
proves the new tests fail when only the new guard is removed.

Corroborating evidence carried in the commit:

- **12 new Jest cases, written first. 8 measured red against the pre-fix components, 4 green.**
- The 4 pre-fix greens are each labelled `[pin: vacuous pre-fix]` in the spec and were each
  **mutation-checked red** under: never clearing the flag; clearing after the `await` instead of in
  `finally`; and a method-wide flag whose clear sits only on the happy path.
- Full suite **168 pass / 11 suites** against a measured `origin/develop` baseline of
  **156 pass / 10 suites**, both fully green — the delta is exactly the new suite. (Per
  `wms2-web-ui`'s known trap, the *tests* count is what was compared, not the suites count.)
- The two double-dispatch cases assert **the transfer has already fired** before the second submit,
  so they cannot silently drift into re-testing 2994's probe guard.

---

## 3. Findings

**1 Medium + 6 Low/Nit — all documentation or test-quality; none behavioural.** F1–F4 were applied
into `20d697d`; F5–F7 were accepted as-is.

### Medium — the stated design rationale was factually wrong

The guard is scoped to the dispatch rather than to the whole method. The pre-review comment justified
that by claiming the method-wide alternative broke the `isDamagedDestination` reason pause. **The lane
measured it: the method-wide shape is 11/11 green on this component, reason pause included** — the
pause's `return` unwinds through a method-wide `finally` and releases the flag. Both shapes are
correct.

The real reason for the narrow scope is narrower and is now stated in the component: widening
requires unwinding **SBDEV-2994's own probe `try/finally`**, which under a method-wide flag drops the
flag mid-method — strictly worse than either shape. That makes widening a refactor of 2994's guard,
not a one-line change.

Why this rated Medium rather than Nit: a wrong rationale in a comment that shouts about a fragile
invariant is what the next maintainer reasons from. The applied fix corrects the component comment
(*"It is NOT rejected for the reason an earlier version of this comment claimed"*) **and** the spec
header (*"Do not read it as 'the guard must not be method-wide'; that property is not tested, because
it is not true"*).

### Low/Nit — the recoverable ones

| # | Finding | Disposition |
|---|---|---|
| — | The `inputAmount` throw case threw from the **store action**, so dropping `submit()`'s `await` in a later refactor would abort the Jest worker and report as a **dead suite** rather than a red assertion. Rewritten to throw from `doSubmit` with a plain non-async stub, making the throw synchronous inside `submit()` | **applied** |
| — | Marked in the spec as **`F2`**: the one case that pins the `await` in `submit()`'s wrapper *without* going near a rejection — dropping it (`this.doSubmit()`) makes the flag true-then-false within one tick, so the case goes red | **applied** |
| — | The double-dispatch cases needed to assert the transfer had **already fired** before the second submit, so they cannot decay into re-testing 2994's probe | **applied** |

> ⚠ **Id collision.** This lane's finding ids and the verify script's row ids both use `F`. The spec's
> `// F2:` comment is **mobile finding F2**, unrelated to **verify row F2**, which grades the
> `OptimisticLockRetry` javadoc in the other lane. Read `F*` in `.vue`/`.spec.js` as findings and `F*`
> in the verify script as rows.

The remaining Low/Nits are not individually recoverable from the artifacts and are not reconstructed
here. Plan §9.1's count (**1 Medium + 6 Low/Nit**, F1–F4 applied, F5–F7 accepted) is the durable
record of the total.

---

## 4. Accepted, not fixed — the one unpinned invariant

The narrow guard rests on a structural property that **nothing automated pins**:

> the gap between the probe's `finally` and `this.submitting = true` must stay **`await`-free** — no
> `await`, no `$nextTick`, no timer. Add one and the guard develops a hole.

Both artifacts say so out loud rather than hiding it — `scanDestination.vue`: *"ADD AN AWAIT IN THAT
GAP AND THIS GUARD DEVELOPS A HOLE"*; spec:28-29: *"No assertion here can pin that — it is a
structural property of the method."*

Accepted for Slice 1 on three grounds:

1. **The hole is not open today** — measured, not assumed: on a single-threaded loop every scanner CR
   and button tap arrives as a separate macrotask and hits the re-entry check.
2. **Slice 2 retires the invariant.** Fix G puts an idempotency key on
   `/v3/stockUnit/transferStock`; once the server dedupes, a client-side hole stops minting phantom
   unit loads regardless of the guard's shape.
3. A structural verify row over that gap would be a **proximity regex over a ~15-line window** —
   precisely the shape this plan already burned five corrected rows on, and which silently asserts
   "same block" until a refactor moves the code.

Recorded here so it is a known accepted risk rather than a discovery for whoever next edits
`submit()`.

---

## 5. Scope confirmations

- `inputAmount.vue` takes the merged **v1** hunk verbatim (`wms-mobile-ui` `b95b5e4`, PR #101) — it
  is byte-identical to its v1 pre-fix version, and keeping v1's guard-wrapper + `doSubmit()` shape is
  what keeps the two repos diffable.
- `inputAmount`'s `selectStockUnit` is a **pure read** (`MoveStockController:66` is a `@GetMapping`),
  so that guard is a UX improvement, **not** part of this defect chain. It is not load-bearing for
  the ticket and should not be described as such in the PR.
- **26 other unguarded scan components per UI remain out of scope** and are recorded in the plan, not
  fixed here.
