---
name: pr291-review2-code
description: Independent round-2 code review of wms2-api PR #291 (SBDEV-3198 step 5 part 1/4, CleanUpOldMessagesJob → D′) at fix commit 15c6a901, verifying round 1's M-1/M-2/L-1..L-5 fixes
lane: code review round 2 (independent — this lane did not author the PR and did not write the round-1 report)
reviewed: 2026-09-03
base: f440b534 (develop tip, post-#288 merge)
round1_head: 55ec08e1
head: 15c6a901
worktree: /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-291-review2-code
---

# PR #291 — independent code review, round 2

## Verdict

**MERGE-READY — with two one-line documentation corrections I would fold in first, and one
sibling-sweep item that must not be lost before step 5 part 2.**

Every round-1 finding that was a code or test defect is genuinely fixed, and I proved it by hand
rather than by reading. M-1's new test is not decoration: I inserted `markLastRun()`,
`markLastSuccess()` and `recordDuration()` into `runForCurrentTenant()` **one at a time**, and each of
the three killed the test on its own distinct assertion line (`:249`, `:251`, `:253`). L-4's new
two-tenant test is a real strengthening, not a rename: I converted `skippedLockBusy()` to the
per-fire shape and it killed **only** the new test, leaving the pre-existing one-tenant test green —
which is exactly the discrimination round 1 said the one-tenant fixture could not make. L-1, L-2, L-5
and the stale "FOUR single-trigger jobs" comment are all correctly landed. The full suite reproduces
the claimed **6252 / 0 failures / 0 errors / 67 skipped** exactly, BUILD SUCCESS.

I tried to break the fixes and could not. The reworded busy-one-key log message is asserted by no
test anywhere in `src/test` (I grepped both the old and the new wording, and confirmed no
`ListAppender` / `OutputCapture` / `LogCaptor` harness exists in any of the ten test files that
reference this job) — so nothing was silently disarmed by rewording it. Moving `startTenantTimer()`
inside the `try` is a strict improvement with no other behavioural consequence: no statement sat
between the old and new positions, and the `finally` chain's stop ordering is unchanged. The
`NeverMatcher` census is untouched because neither new test uses `never()`.

What I did find is four things this round of fixes introduced or left behind, none of them a code
defect and none of them capable of failing a build — which is precisely why they need naming:

- **N-4** — L-4's own javadoc fix **cites the wrong test**. It names the one-tenant test that asserts
  `1.0`, in the sentence whose point is that the answer is `2.0`. One word.
- **N-1** — the PR description and the plan document now **flatly contradict each other** on whether
  M-2 is decided or still open.
- **N-2 / N-3** — the M-2 log reword and the L-1 timer move were each applied to **one of the two**
  jobs carrying the identical pattern. `StockSummaryExportJob` — the other dual-form lock holder, and
  the file parts 2–4 of step 5 will clone from — still has both pre-fix shapes verbatim.

Counts: **0 High**, **0 Medium**, **4 Low (all new this round)**. All six round-1 findings:
**RESOLVED** (M-2 as an explicitly recorded accepted-risk decision plus the cheap mitigation, which
is what round 1 asked for).

## Evidence collected

| Instrument | Result |
|---|---|
| `mvn -o clean test` (full suite, HEAD `15c6a901`) | **6252 run, 0 failures, 0 errors, 67 skipped** — BUILD SUCCESS, 4m04s. Matches the PR's claim exactly; +2 over round 1's measured 6250 at `55ec08e1` |
| Hand mutant **A** — `jobMetrics.markLastRun()` alone into `runForCurrentTenant()`'s try | **KILLED** — `doesNotTouchTheWholeRunGauges` fails at `:249` (`expected: 0.0`) |
| Hand mutant **A2** — `jobMetrics.recordDuration(1L)` alone | **KILLED** — same test, fails at `:253` (the duration-timer `isNull` assertion) |
| Hand mutant **A3** — `jobMetrics.markLastSuccess()` alone | **KILLED** — same test, fails at `:251` |
| Hand mutant **B** — `skippedLockBusy()` made per-FIRE (`if (!busyReported) {…}` hoisted flag) | **KILLED, and selectively**: `tryLockBusy_twoTenantGroup_incrementsSkippedLockBusyPerTenant` fails at `:156` (`expected: 2.0`); the pre-existing one-tenant `tryLockBusy_incrementsSkippedLockBusyCounter` stays **green**. Proves the new test adds discrimination the old one lacked |
| `git diff --stat 55ec08e1 15c6a901` | 4 files, +96 / −22. One `src/main` file, three test files. No plan/verify/config file touched |
| `grep -rn "old-code\|dual-lock deploy note\|one-key lock held\|one-key lock not acquired\|connection pool is exhausted" src/test/` | **1 hit**, and it is a *comment* (`StockSummaryExportJobTest:503`), not an assertion. No test asserts either wording — the reword breaks nothing |
| `grep -rln "ListAppender\|OutputCapture\|LogCaptor" src/test` ∩ the 10 files referencing `CleanUpOldMessagesJob` | The two intersecting files (`SchedulingConfigurationUnitTest`, `SchedulingReconcileIdempotencyUnitTest`) capture `SchedulingConfiguration`'s logger, not the job's. No log-text coupling anywhere |
| `grep -n "maximum-pool-size" src/main/resources/application.properties` | `:66 landlord.datasource.maximum-pool-size=2` — unchanged, as expected |
| `grep -rn "one-key lock\|old-code" src/main/java/` | The pre-fix message survives verbatim at `StockSummaryExportJob:267-268`. See N-2 |
| `grep -rn "startTenantTimer()" src/main/java/` | 5 call sites. `CleanUpOldMessagesJob:227` is now inside its `try`; `StockSummaryExportJob:279` is still outside. The other three (`OrderReleaseJob`, `ReplenishOrderJob`, `ReleaseExpiredPickingOrdersFromUserJob`) are step 5 parts 2–4, not yet converted and holding no dual lock — correctly out of scope. See N-3 |
| `grep -rn "FOUR single-trigger\|THREE single-trigger" src/` | `SchedulingReconcileIdempotencyUnitTest:224` now says THREE ✔. `:491`'s surviving "FOUR" is a **different and correct** claim (four new *registrations*), and its own text says "no longer 'four single-trigger jobs'" — not stale |
| `V2.2.20__authorization_join_table_primary_keys.sql:353-359`, read in full | The javadoc's new wording is a faithful paraphrase: "that table can ALREADY hold duplicate ids, silently" / "A PK … would convert that into a permanently failing archive job" ✔ |
| `NeverMatcherNullBlindnessArchTest:391` | `154 across 39 as of 2026-09-03` — matches the corrected PR body (148→154 / 37→39). Neither new test uses `never()`, so the census is genuinely unmoved, and the green suite confirms it |
| `StockSummaryExportJobUnitTest:414-434` vs the new `CleanUpOldMessagesJobUnitTest:239-254` | Assertion form is identical (registry-based, four assertions, same meter names modulo job segment). Round 1's prescribed shape followed exactly |

Worktree restored to a clean `15c6a901` after every mutation — `git status --porcelain` empty,
verified after each pair and at the end.

---

## M-1 — **RESOLVED**, and pinned three ways rather than one

`CleanUpOldMessagesJobUnitTest:239-254` (`RunForCurrentTenantLocking#doesNotTouchTheWholeRunGauges`)

The test exists, is named as round 1 predicted, and asserts on the `SimpleMeterRegistry` directly —
not `verify(mock, never())`, which was unavailable because this fixture's `JobMetrics` is real. The
fixture was correctly refactored to hoist the registry into a field (`:129`, `:133`, `:136`) rather
than constructing it inline, so the test can reach it. This is byte-for-byte the shape round 1
recommended and the shape step 4's equivalent uses.

I did not take the "one mutant, one kill" answer. The javadoc claim has three distinct halves
(`markLastRun`, `recordDuration`, `skippedLockBusy`) and the test carries four assertions, so I
inserted the gauge calls **individually** to check that no assertion is riding on another's coattails:

| Inserted alone into `runForCurrentTenant()`'s try | Test outcome |
|---|---|
| `jobMetrics.markLastRun();` | FAIL at `:249` — `expected: 0.0` |
| `jobMetrics.markLastSuccess();` | FAIL at `:251` |
| `jobMetrics.recordDuration(1L);` | FAIL at `:253` |

Three separate assertion lines, three separate kills. The fourth assertion
(`skipped_lock_busy` counter `isNull`, `:252`) is structurally unreachable in this test's path — the
two-key `tryLock` is stubbed `true`, so `runForCurrentTenant()` has no branch that could increment it
— but it is harmless and mirrors step 4, so I am not filing it.

Round 1's finding was that a mutant reversing this claim survived the entire 6250-test suite. It no
longer does. **Genuinely closed.**

## M-2 — **RESOLVED as far as this PR can resolve it**; the mitigation landed and the documentation is honest

`CleanUpOldMessagesJob.java:202-213`; `application.properties:66`; plan `§7a step 5`

Three checks, all pass:

1. **The wording no longer asserts a cause it cannot distinguish.** `:207-210` now reads *"one-key
   lock not acquired (an old-code replica holds it — expected during the dual-lock transitional
   window — or the landlord connection pool is exhausted)"*, with a code comment at `:203-206`
   naming the reason both produce an indistinguishable `false`. That is exactly the reword round 1
   proposed, and it preserves the transitional framing rather than discarding it.
2. **`landlord.datasource.maximum-pool-size` is still `2`** — correctly unchanged. Round 1 did not
   ask for a code change here and a speculative bump would have been wrong.
3. **The plan documents this as still-open-and-decided, not silently resolved.** Plan `§7a step 5`
   records it as *"M-2 — DECIDED 2026-09-03, risk explicitly accepted, not a code defect"*, states
   plainly that the #288 round-2 deadline *"was crossed without a reading"*, names the obstacle
   (DB/actuator MCP unavailable for a third consecutive session — I hit the identical
   `CONNECT_TIMEOUT` on all twelve servers this session), records the reasoning, and marks the live
   reading as *"a nice-to-have, not a gate"* for parts 2–4.

Worth adding, because neither review round has cited it and it materially de-risks the item: the plan
**already contains a measurement that contradicts the in-repo cap**. `§2.3` (plan `:236-258`) records
that prd shows **~20 idle `PostgreSQL JDBC Driver` connections** to `wms2_landlord` against a claimed
2-per-JVM over ~2 containers — *"a factor-of-five contradiction at minimum"* — concluding the cap is
overridden in the Portainer stack environment exactly as `app.cron` is. The accepted-risk paragraph
at `§7a step 5` reasons from the in-repo `2` without pointing at that section. The decision is
unaffected (it is conservative), but a reader of the decision alone will think the evidence is weaker
than it is. A cross-reference would cost one clause.

Nothing here is a code defect and nothing blocks this PR. **See N-1 and N-2** for what this fix left
inconsistent.

## L-1 — **RESOLVED**

`CleanUpOldMessagesJob.java:220-227`

The two-key lock is acquired at `:215`; the `try` whose `finally` (`:241-243`) releases it opens at
`:220`; `tenantSample = jobMetrics.startTenantTimer();` is at `:227` — the first *statement* inside
that `try`, preceded only by a six-line comment. Round 2's N-5 on step 4 named this PR as the place
the fix belonged and the fix is here.

No test can pin this and I am not asking for one: `Timer.start(registry)` does not throw, so the leak
it prevents is unreachable, exactly as N-5 said. I verified the placement by reading and confirmed by
tracing the exception paths that the move is otherwise inert — see §8 below. **See N-3** for the
sibling.

## L-2 — **RESOLVED**, and the citation now matches the migration verbatim in substance

`CleanUpOldMessagesJob.java:34-43`

I read `V2.2.20__authorization_join_table_primary_keys.sql:353-359` in full rather than trusting
round 1's excerpt. The migration says `message_archived` is deliberately left without a PK because an
interrupted archive-then-delete cycle re-archives on the next run, *"that table can ALREADY hold
duplicate ids, silently"*, and a PK *"would convert that into a permanently failing archive job on
any affected tenant."*

The new javadoc says precisely that, then re-states the dual-lock's justification as **amplification
of an already-tolerated condition** rather than as novel unguarded corruption: *"the dual-lock is not
preventing NOVEL corruption — it is preventing a ROLLING DEPLOY from amplifying that already-tolerated
condition … during every drain window rather than only on the rare interrupted-cycle path the table
already accepts."* Accurate, and the decision correctly does not change. The PR description carries
the same correction at its own line 11.

## L-4 — **RESOLVED in substance**; see **N-4** for a defect introduced by the fix itself

`CleanUpOldMessagesJob.java:69-78`; `CleanUpOldMessagesJobMetricsUnitTest:136-157`

Both halves landed:

- The javadoc now states both semantics **in this job's own class**, as bullets, rather than
  redirecting to `StockSummaryExportJob`. I verified the second bullet's claim against the code
  independently: a fire where every member tenant `continue`s at `:212` leaves `anyFailure` false, so
  `markLastSuccess()` at `:266` runs with zero archives — the javadoc is correct.
- The new two-tenant test is real. Both fixture tenants derive the same spec (both `WH01` and the new
  `WH02` are stubbed to `America/Los_Angeles`, and the hour/minute sysprop stubs are shared), so both
  are genuine group members that reach the one-key `tryLock`.

**Mutation-checked, because "added a test asserting 2.0" is not by itself evidence of a
strengthening.** I converted `skippedLockBusy()` to the per-fire shape round 1 said the old fixture
could not detect:

```java
boolean busyReported = false;               // hoisted above the tenant loop
…
if (!busyReported) { jobMetrics.skippedLockBusy(); busyReported = true; }
```

Result: `tryLockBusy_twoTenantGroup_incrementsSkippedLockBusyPerTenant` **FAILED** at `:156`
(`expected: 2.0`) while `tryLockBusy_incrementsSkippedLockBusyCounter` — the original one-tenant test
— stayed **green**. That is the discrimination round 1 asked for, demonstrated rather than asserted,
and it confirms the new test is additive rather than a rename (both tests exist and both run).

## L-5 — **RESOLVED**

`CleanUpOldMessagesJob.java:80-84`. The javadoc now discloses that `tenant_duration`'s population
narrowed from "every active tenant including non-members" to "member tenants whose archive actually
runs", and correctly frames it as matching the already-reviewed step 3/4 shape rather than as a
divergence. Matches what the code does (`tenantSample` is `null` until `:227`, stopped only under
`if (tenantSample != null)` at `:253`).

## L-3 / item 7 — **RESOLVED**

The PR body's `NeverMatcher` census now reads **148→154 across 37→39**, matching
`NeverMatcherNullBlindnessArchTest:391` and the green ArchTest.

The stale comment at `SchedulingReconcileIdempotencyUnitTest:224` now says **THREE** single-trigger
jobs and explains the change (*"was FOUR before step 5 moved cleanUpOldMessages into the grouped set
too"*). I swept the whole file rather than checking the one line: the only other surviving "FOUR" is
at `:491`, and it is a **different, correct** claim — four new *registrations* — whose own text
already says *"but no longer 'four single-trigger jobs'"*. No stale count remains in that file, in
`SchedulingConfigurationUnitTest`, or in `SchedulingConfiguration.java` (all "three single-trigger"
references check out).

---

## N-1 (Low, new) — the PR description and the plan document now say opposite things about whether M-2 is decided

PR #291 body (line 37) vs plan `SBDEV-3198-per-tenant-cron-scheduling.md` `§7a step 5`

The PR body says:

> **Not a code defect, still open** … **This decision genuinely needs to be made — either read the
> pool cap, or explicitly accept the risk — before parts 2–4 of step 5 add two more dual-form
> holders.**

The plan says:

> **M-2 — DECIDED 2026-09-03, risk explicitly accepted, not a code defect.** … **Not a blocker for
> parts 2–4 going forward** — the live-cap reading remains a nice-to-have, not a gate.

These cannot both be current. The likeliest reading is that the plan was updated after the decision
was taken and the PR body was not — but I cannot verify which is authoritative from inside this
worktree, and I am deliberately not adjudicating whether the decision was in fact made. What matters
for review is the consequence: **whoever picks up step 5 part 2 will read one of these two documents
and get the opposite instruction about whether a gate exists.** M-2's entire history is a deadline
that slipped across three sessions because nobody could tell whether it was still open; shipping two
artifacts that disagree on exactly that question re-creates the condition.

**Fix:** one paragraph in the PR description, to match the plan.

## N-2 (Low, new) — the M-2 log reword landed on one of the two dual-form lock holders; the misleading message survives verbatim in the other

`StockSummaryExportJob.java:267-268`

```java
LOG.warn("{} for {} - {} skipped this occurrence — one-key lock held (old-code "
    + "replica), transitional per the dual-lock deploy note",
```

That is the exact string M-2 was raised about, still asserting a cause it cannot distinguish, in the
**other** job that holds both lock forms on one thread. M-2's own analysis is what makes this matter:
round 1 established that there are exactly two such jobs and that the operator-facing risk is a
pool-exhaustion event being read as an unconverted replica. Rewording one of the two leaves half the
exposure in place, and leaves the two files divergent on a line a reader would reasonably expect to
be identical (this PR's whole design argument is that it mirrors step 4).

This is the repo's sibling-sweep rule applied literally: the pattern fixed here has exactly one
sibling in `src/main`, and it is untouched. `grep -rn "one-key lock\|old-code" src/main/java/`
returns the full population — the other three `startTenantTimer` jobs (`OrderReleaseJob`,
`ReplenishOrderJob`, `ReleaseExpiredPickingOrdersFromUserJob`) hold no dual lock yet and are
correctly out of scope.

**Fix:** copy the new wording into `StockSummaryExportJob:267`. No test asserts either string
(verified by grep across all of `src/test`), so this is a zero-risk edit.

## N-3 (Low, new) — same sibling gap for L-1: the file parts 2–4 will clone from still has the pre-fix timer placement

`StockSummaryExportJob.java:279`

```java
                        }
                        tenantSample = jobMetrics.startTenantTimer();   // ← still OUTSIDE the try
                        try {
```

PR #288's round-2 review filed this as N-5, called it pre-existing, and assigned the fix to *"step
5's clone"*. Step 5's clone is fixed. The original is not, so the two files have now **diverged** on
a line that was previously identical.

I am recording this not because the leak is reachable — it is not, as both reviews have said — but
because of the forward consequence. The PR description states that `configureCleanUpOldMessagesGroups`
*"mirrors `configureStockSummaryExportGroups` exactly"* and round 1 proved that with a normalized
diff; the working method for step 5 is demonstrably "clone the step-4 reference and substitute
identifiers." Parts 2, 3 and 4 will therefore clone `StockSummaryExportJob` — and pick up the shape
this PR just fixed, three more times, unless the reference is corrected. Deferring it a second time
costs three future fixes instead of one.

**Fix:** one line in `StockSummaryExportJob`, ideally in this PR since it is already the file's
reviewer.

## N-4 (Low, new) — L-4's javadoc fix cites the wrong test, and the test it cites asserts the value the sentence says is wrong

`CleanUpOldMessagesJob.java:70-73`

```
 *   <li>{@code skippedLockBusy} is recorded once per LOCK-BUSY MEMBER TENANT, not once per group
 *       fire — a two-tenant group where both find the one-key lock busy records {@code 2.0}, not
 *       {@code 1.0}. Pinned by {@code CleanUpOldMessagesJobMetricsUnitTest
 *       .tryLockBusy_incrementsSkippedLockBusyCounter} against a two-tenant fixture.</li>
```

`tryLockBusy_incrementsSkippedLockBusyCounter` is the **one-tenant** test at
`CleanUpOldMessagesJobMetricsUnitTest:118`, and it asserts `isEqualTo(1.0)` — the exact value this
sentence identifies as the wrong answer. The two-tenant test the sentence means is
`tryLockBusy_twoTenantGroup_incrementsSkippedLockBusyPerTenant` at `:138`.

So the javadoc names a test that does not have a two-tenant fixture and does not assert `2.0`. The
failure mode is concrete and self-defeating: a future reader who does the right thing — grep the
cited pin to confirm the claim — lands on an assertion of `1.0` and concludes either that the javadoc
is wrong or that the pin was weakened, and the plausible "correction" is to edit the javadoc to match
the test. That is the same class of defect L-4 itself was: a citation that reads as stronger evidence
than it is. It is also the one thing in this diff that a reader is *most* likely to check, because
L-4's fix is what put the citation there.

Worth noting that `StockSummaryExportJob:85` states the same `2.0`-not-`1.0` semantics for its own
job and cites nothing at all, so there is no precedent being broken here — this is a fresh error, not
an inherited one.

**Fix:** one identifier. `tryLockBusy_incrementsSkippedLockBusyCounter` →
`tryLockBusy_twoTenantGroup_incrementsSkippedLockBusyPerTenant`.

---

## Verified — what I tried to break and could not

**Nothing in the codebase is coupled to the busy-one-key log text.** This was the most plausible way
for the M-2 reword to have silently broken something, so I checked it two ways rather than one. A
grep for both the old wording (`one-key lock held`, `dual-lock deploy note`, `old-code`) and the new
(`one-key lock not acquired`, `connection pool is exhausted`) across all of `src/test` returns exactly
one hit, and it is a `//` comment in `StockSummaryExportJobTest:503` describing a test's intent — not
an assertion, and not even in this job's test files. Independently, I intersected the set of files
using a log-capture harness (`ListAppender` / `OutputCapture` / `LogCaptor`) with the ten files that
reference `CleanUpOldMessagesJob`: the two files in both sets capture `SchedulingConfiguration`'s
logger, not this job's. There is no path by which the reword could have disarmed an assertion.

**Moving `startTenantTimer()` inside the `try` changes no exception-handling behaviour beyond the
one it was meant to fix.** I traced all three enclosing handlers. Before: a throw at that point
unwound through the `finally` at `:244-246` (one-key release only), then the `catch` at `:247`, then
the outer `finally` at `:252-255`. After: it additionally passes through `:241-243`, releasing the
two-key form — which is the entire point. Nothing else moved: **no statement sat between the old and
new positions** (the old line was immediately above the `try`, and the new line is immediately inside
it), `tenantSample` remains `null` if the call throws so the `if (tenantSample != null)` guard at
`:253` still holds, and the stop-ordering in the `finally` chain (two-key unlock → one-key unlock →
`stopTenantTimer` → `TenantContext.clear()`) is unchanged. The `tenant_duration` timer's measured span
is unchanged to within the statements between the two positions, of which there are none.

**The two new tests cannot have moved the `NeverMatcher` census, and did not.** Neither
`doesNotTouchTheWholeRunGauges` nor `tryLockBusy_twoTenantGroup_incrementsSkippedLockBusyPerTenant`
contains a `never()` span, so the per-class inventory at `NeverMatcherNullBlindnessArchTest:391`
(`154 across 39 classes as of 2026-09-03`) is correct unchanged — and because that test asserts
**exact per-class equality** in both directions (deliberately, per its own javadoc), the green suite
is itself proof, not merely consistent with it.

**The M-1 fixture refactor did not weaken the five pre-existing tests in that nested class.** The only
change to `RunForCurrentTenantLocking`'s setup is hoisting the `SimpleMeterRegistry` from an inline
constructor argument to a field so the new test can read it — the `JobMetrics` instance, the job
construction, the mocks and the `TenantContext` setup are byte-identical. All six tests in the class
run and pass at HEAD (`Tests run: 6, Failures: 0` in the class-scoped run), and under each of my three
mutants exactly one test failed and the other five stayed green, which is what a non-interfering
fixture change looks like.

**The full suite is genuinely at the claimed number, on a clean tree.** `6252 / 0 / 0 / 67`, BUILD
SUCCESS, 4m04s, run as `mvn -o clean test` (with `clean`, so no stale `target/test-classes` could
inflate or deflate the count). +2 over round 1's independently measured 6250 at `55ec08e1`, which is
exactly the two tests added — the arithmetic reconciles without slack.

**Round 1's own verified section still holds where this diff touched it.** The `runFor` dual-lock
structure, the per-tenant nesting, the release ordering and the five `runForCurrentTenant` refusal
paths are untouched by `15c6a901` (the `src/main` diff is javadoc, one log-message string, one comment
block and one moved assignment), so I did not re-run round 1's seven structural mutants — re-verifying
unchanged lines is not where this round's budget belonged. The one structural line that *did* move,
`startTenantTimer()`, I traced by hand above.

---

## Recommended pre-merge set

1. **N-4** — one identifier in `CleanUpOldMessagesJob:72-73`. The javadoc's own pin citation is wrong
   and points at a test asserting the value the sentence calls incorrect. Cheapest fix in this list
   and the one most likely to be checked by a reader.
2. **N-1** — align the PR description's M-2 paragraph with the plan's recorded decision. One
   paragraph.
3. **N-2 / N-3** — copy both fixes into `StockSummaryExportJob` (`:267` message, `:279` timer
   placement). Two lines. If this is deferred, it must land **before step 5 part 2**, because that
   file is the template parts 2–4 clone from and deferring turns one fix into three.

None of the four blocks merge on correctness grounds, and I would not hold the PR if the team prefers
to fold N-2/N-3 into part 2's PR. But per this repo's standing convention that Low findings are fixed
in the same pass, all four are same-pass work — the total is roughly five lines.

Nothing in this round disputes the design, and nothing round 1 raised remains open as a defect. The
M-1 and L-4 fixes in particular are the good kind: they do not merely satisfy the finding, they are
independently mutation-provable, and I confirmed each one by breaking it myself.
