# Review — `26ad2323` "correct the barrier-timeout diagnosis and four review Lows"

Lane: `lane-relandfixreview` · 2026-10-05
Worktree: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3637-reland`
Subject: `26ad2323` only, +50/−29 in `src/test/java/net/aim_ai/wms/service/ReplenishRedirectLockOrderIT.java`.
Prior review of the parent `79dc3642`: `review-reland-test.md` (1 MEDIUM + 4 LOW).

**Verdict: APPROVE-WITH-FIXES.** L-1 through L-4 are all correctly fixed and the mechanism is
untouched. M-1 is **not** correctly fixed: the replacement trades one false claim for a weaker but
still false one. It is the seventh wrong safety claim on this ticket.

| Item | Status |
|---|---|
| M-1 barrier-timeout diagnosis | **PARTIAL — new overstatement (MAJOR)** |
| L-1 `>= 2` retry condition | FIXED |
| L-2 `failures` before `bothSeized` | FIXED |
| L-3 counterfactual log line | FIXED |
| L-4 residual 1 "single-threaded probe" | FIXED |
| Mechanism unchanged | CONFIRMED |

---

## MAJOR — M-1's replacement is itself false: a blocking regression **does** reach barrier 3

### The claim

`ReplenishRedirectLockOrderIT.leg`, barrier-timeout arm:

> `"do NOT read this as a reinstated BLOCKING target acquisition "`
> `+ "(skip-locked removed or bypassed) — that regression cannot reach "`
> `+ "this barrier."`

and class javadoc residual 4:

> `<b>A 60s barrier timeout is NOT how a lock-order regression shows up here.</b>`
> …
> `Such a regression therefore surfaces on the {@code failures} assertion, never as a harness timeout.`

### Why it is false

Trace the regression the sentence names (move-path target acquisition blocking again), against the
code in this commit:

1. Both legs seize their own source, clear `sourceBarrier`, clear `moveBarrier`, and enter
   `transferUnitLoadToLocation` — barrier 2 is inside `move(...)`, immediately before the transfer:
   > `beforeTransfer.await(60, TimeUnit.SECONDS);`
   > `unitloadBusinessService.transferUnitLoadToLocation(ul, dest, true, MOVE, …);`
2. Each leg now waits on the other's source. The detector fires at ~1s and kills **one** leg. That
   leg's `RuntimeException` hits
   > `} catch (RuntimeException e) {`
   > `    throw e;`
   rolls back, and the leg returns its Throwable **without ever calling `commitBarrier.await`**.
   This half of the new text is correct.
3. The **surviving** leg now acquires the freed source, finishes its move, and executes
   > `commitBarrier.await(60, TimeUnit.SECONDS);`
   Nobody else will ever arrive at that barrier. It waits the full 60s and throws `TimeoutException`
   → the barrier-timeout arm → **this message**.

So the regression produces a barrier timeout on every run, on the surviving leg, 60 seconds after
the abort. "That regression cannot reach this barrier" is wrong about the only leg that can reach it.
The same holds for the one-sided `55P03` shape at 10s.

Derivation method: direct reading of `leg(...)`, `move(...)`, `runInvertedPairChoreography()` in the
post-commit file; `CyclicBarrier` semantics (a thread that never calls `await` does not break the
barrier — only an interrupt, a timeout or a `reset` does, and nothing here calls `reset`). Blind
spots: I did not execute the scenario (no Maven, per brief), and I did not enumerate whether some
acquisition inside `transferUnitLoadToLocation` runs outside the tenant transaction manager and so
outside the `SET LOCAL lock_timeout` bound — the prior review flagged that same blind spot.

The prior review's own words already contain this: *"`blockedBackendSnapshot()` would report zero in
both cases because the blocked backend has already errored out **by the time the surviving leg's
barrier expires**."* The remedy it prescribed dropped that qualifier, and this commit hardened the
unqualified version into an explicit "cannot".

### Realist check

Mitigated by three things, which is why this is MAJOR and not CRITICAL:

- the barrier-timeout `IllegalStateException` lands in `failures` alongside the `40P01` throwable,
  and `assertThat(observed.failures()).isEmpty()` prints both;
- that assertion's own description renders `sqlStates(observed.failures())`, so the header reads
  `SQLSTATEs raised: [40P01]` — the correct diagnosis is printed one screen above the wrong one;
- the message's second half ("a leg that died before reaching its await … find which leg died, and
  why") does route a careful reader to the right place.

Realistic worst case: a reader sees the 60s timeout, reads "do NOT read this as a reinstated
BLOCKING target acquisition", and stops looking — in exactly the scenario the message exists to
catch. Detection is at human read time, not automatic. No data, security or financial exposure.

### Fix

Both sites, same substance. Replace the "cannot reach this barrier" sentence with the leg-specific
version it should have been:

> A timeout here is never the *blocked* leg — a blocked leg aborts at `40P01` (~1s) or `55P03` (10s),
> ~50s sooner, and lands on the `failures` assertion; IT-1a pins `deadlock_timeout < lock_timeout`.
> It is the leg that SURVIVED, waiting for a counterpart that died before its await. So read the
> OTHER entry in the failure list: a `40P01`/`55P03` there **is** a reinstated blocking acquisition.
> Only an empty failure list beside this one means a pathologically slow lane.

That keeps everything the fix got right (the abort is ~50s earlier; the blocked leg never reaches
here; a zero snapshot does not exonerate) and removes the one inference that does not follow.

---

## M-1 sub-claims, checked individually

**(a) Timings and their two property sources — TRUE, grounded in the worktree.**
`src/test/resources/application-postgres-integration.properties:187` → `wms.tenant.lock-timeout-ms=10000`;
`BasePostgresIntegrationTest` carries `@ActiveProfiles("postgres-integration")`, so that file is the
one in force for this class. `deadlock_timeout` is not overridden anywhere: `AppPostgresDBContainer`
sets only database/user/password/reuse — no `withCommand`, no init script — so PostgreSQL's 1000ms
default stands, and IT-1a reads it from `pg_settings` at runtime rather than assuming it. Both
numbers in the new text are right. (Method: `git grep` for each property name across `src`, plus
reading the container class in full. Blind spot: an env-var override at the Docker daemon level
would not appear in-repo.)

**(b) "points at `failures`" / "IT-1a pins that ordering" — the first is right, the second
overclaims (MINOR).** The abort does land in `failures` (every leg Throwable is collected in
`runInvertedPairChoreography`, and `failures` is now asserted first). But IT-1a —
`tenantLockTimeoutExceedsDeadlockTimeout()` — asserts exactly one thing:
> `.isGreaterThan(deadlockTimeoutMs)`
It grades `lock_timeout > deadlock_timeout`. It never sees the 60s barrier constant, so it does not
pin "aborts before the barrier", which is the ordering the sentence attaches it to. Narrow the
citation to what IT-1a measures.

**(c) "a ZERO does not exonerate the lock order" — TRUE.** At the instant of the surviving leg's
timeout the aborted leg's backend is long gone and the surviving leg is not itself blocked (the
`blockedBackendSnapshot` javadoc says so), so the query returns zero rows. The caveat is correct and
is the most valuable sentence added by this commit.

**(d) All three sites corrected — YES, no copy survives.** Sweep:
`git grep -nE "BLOCKING again|blocking-acquisition regression|disguise a real regression|likeliest cause is NOT a slow machine" -- src`.
Positive control first: the same pattern against the pre-commit blob
(`git show 79dc3642:src/.../ReplenishRedirectLockOrderIT.java`) returns **3** hits — the leg arm, the
residual-4 bullet and `blockedBackendSnapshot()`'s return string, i.e. the instrument does fire when
the text is present. Post-commit it returns **1**, and that one is the *new* residual-4 sentence
reusing the phrase "BLOCKING again" to name the hypothetical it then refutes, not an uncorrected
copy. So all three old copies are gone and the correction landed in all three.

Blind spot, worth stating because it bit this very scan: `git grep` is line-oriented and these
strings are split across Java concatenation, so a pattern spanning a `" + "` boundary silently
misses — my first attempt at `"cannot reach this barrier"` returned nothing even though the sentence
is there, split across two source lines. Every pattern above was chosen to sit inside one literal.
Scope: `src` only; the plan document and the other evidence files were out of scope per the brief.

Note the snapshot string is the one site that came out clean — it now says only what a non-zero and
a zero each license. One residual nit there, MINOR: *"a NON-ZERO count here means a backend really
was waiting on a row lock, i.e. the move path is blocking where it is supposed to skip"* — the query
filters on `datname = current_database()` and nothing else, with no pid or fixture scoping, so on a
reused container shared with a concurrent run a stranger's blocked backend counts. The file knows
this: `readBlockedBackend` asserts *"exactly ONE backend may be blocked by this test's holder; more
means a stranger is contending."* The `i.e.` should be "some backend was waiting — confirm it is
this test's before concluding anything about the move path."

---

## L-1 — `interleaved = contendedLines.size() >= 2` — FIXED

> `interleaved = contendedLines.size() >= 2;`

A `>2` outcome now exits the loop and reaches
> `.hasSize(2);`
which fails on the attempt that produced it. Confirmed by reading the loop: `interleaved` is the
only loop guard besides `attempt <= MAX_INTERLEAVING_ATTEMPTS`, and the post-loop block runs
unconditionally.

Can `>= 2` make the loop exit on a shape that should retry? No. The retryable condition is "fewer
than two contended lines **and** an empty failure list"; `failures` is asserted empty earlier in the
same iteration, so by the time `interleaved` is computed the failure half is already discharged, and
`>= 2` is the exact complement of "fewer than two". Sizes 0 and 1 still retry, unchanged.

MINOR: on a size-3 attempt the post-loop log prints `interleaving ACHIEVED` immediately before
`hasSize(2)` fails. Harmless — the failure is the next line — but "ACHIEVED" is the wrong word for a
shape that is about to be graded as wrong.

## L-2 — `failures` asserted before `bothSeized` — FIXED, and strictly correct

A leg can only fail to set `seized` by throwing, because the two statements are adjacent and
unconditional:
> `stockunitRepository.findByIdForUpdate(stockUnitId).orElseThrow();`
> `seized.set(true);`
So `bothSeized() == false` **implies** a non-empty `failures`. Asserting `failures` first therefore
cannot steal a report from any case where `bothSeized` was the real cause — there is no such case.
The reverse (the old order) could and did hide the Throwable. Reordering is sound in both
directions; no other assertion's reporting changed.

## L-3 — counterfactual log line — FIXED

> `"… — this is how many choreography attempts were needed; 1 is the expected value now that barrier 3 forces the interleaving, and any count above 1 is itself a finding worth reporting"`

States what the number means and nothing the measurement cannot support. The "barrier 3 forces the
interleaving" premise is pre-existing and sound: both sources are held from before barrier 1 until
after barrier 3, so each leg's target acquisition is necessarily contended.

## L-4 — residual 1 — FIXED

> `"…and it does so with a SINGLE service-under-test worker running against a separately parked holder connection, not with two symmetric legs."`

Accurate: `runRecalcProbe` parks `Connection holder` with `setAutoCommit(false)` and a
`SELECT id FROM stockunit WHERE id = … FOR UPDATE`, then runs `recalculateForItem(ITEMDATA)` on an
`Executors.newSingleThreadExecutor()`. Substance intact — the bullet still says IT-2's control is the
only thing distinguishing "skip-locks every edge" from "skip-locks only the inverting one".

## Mechanism — CONFIRMED UNCHANGED

The diff is +50/−29 and every hunk is javadoc, a diagnostic string, the assertion **order**, or the
`==`→`>=` comparator. Untouched, verified by reading the post-commit file: the three
`CyclicBarrier(2)` constructions and all four `await(60, TimeUnit.SECONDS)` call sites; the
fail-immediately set (`bothSeized`, any leg Throwable, any `BrokenBarrierException`/`TimeoutException`,
both `Future.get(120, TimeUnit.SECONDS)` calls); `.hasSize(2)`; and the token
> `linesContaining(captured, "SBDEV-3637 REDIRECT_CONTENDED")`
which is a literal `contains` on the full token and so cannot also match `REDIRECT_NO_HEAL`.

## Evidence consistency

`ReplenishRedirectLockOrderIT` 4/4 green with `interleaving ACHIEVED after 1 attempt` is consistent
with this commit: nothing in it changes a code path the green run exercises. The reported run says
nothing either way about the M-1 finding, which concerns only what the harness *prints* in a failure
mode that did not occur. Parent-commit suite figures (surefire 7814/0F, failsafe 635/0F, 122 IT
classes) are unaffected by a comment-and-ordering change. No inconsistency found. NOT ESTABLISHED:
whether the blocking-regression scenario actually costs the extra 60s in practice — settling probe
would be to revert the skip-lock in a scratch worktree and run IT-1e once, which the brief forbids.

---

**VERDICT: APPROVE-WITH-FIXES** — land the two-site M-1 rewording (plus the IT-1a citation narrowing
and the snapshot `i.e.`) before this goes anywhere. L-1 to L-4 need no further work.
