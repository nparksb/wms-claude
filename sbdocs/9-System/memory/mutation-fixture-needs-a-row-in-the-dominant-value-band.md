---
name: mutation-fixture-needs-a-row-in-the-dominant-value-band
description: "A comparison-operator mutant survives any fixture that has no row in the value band holding most real data — `state <` -> `<>` passed 3 green tests while it would have halted replenishment on 99.8% of rows"
metadata:
  node_type: memory
  type: feedback
---

**Mutating `<` to `<=` is the obvious mutant and it is the WEAK one. `<` to `<>` is the dangerous one, and a
fixture built around the boundary will not catch it.**

Measured on SBDEV-3153. The predicate is `ro.state < :replenishOrderStatus` with the parameter always `700`.
My first fixture had orders at states 100, 100, 100 and 700 — boundary coverage, which killed `<` → `<=`
(the 700 row flips). It did **not** kill `<` → `<>`: with `<>` the 100s still block (100 ≠ 700) and the 700
still does not (700 = 700), so the expected set was unchanged and all three tests stayed green.

The mutant is catastrophic. On `dev_wh01_om1`, `replenishorder` states are `300: 565`, `700: 170`,
**`800: 388,355`** — 99.8% of rows sit *above* the bound, exactly where `< 700` and `<> 700` disagree. Under
the mutant every closed order in history becomes a blocker and replenishment generation stops silently on both
the cron and the mobile-confirm path. One fixture row at state 800 kills it.

**Why:** `SELECT state, count(*) GROUP BY state` before writing the fixture — the mutant that matters lives
in whichever band holds the mass, and that band is usually *not* near the boundary you were thinking about.

Generalises past comparisons: **a fixture proves a predicate only over the value bands it populates.** Two
adjacent survivors in the same fixture, both real: `stockunit.amount < fla.lowerbound` → `<=` (5 vs 10, true
either way) and `fla.active = 'true'` (no inactive row at all).

Corollary from the same session: a **behavioural** twin-comparison test could not see a re-inlined query that
differed only by `amount <= lowerbound` (fixture-invisible), while a two-line **structural** assertion
comparing the two `@Query` strings from `FROM` onward killed it immediately. When you own two copies of a
predicate, pin them structurally as well as behaviourally. Related: [[mutation-harness-traps]],
[[green-tests-that-prove-nothing]], [[sbdev-3153-refill-or-split]].
