---
name: pr288-review2-code
description: Independent round-2 code review of wms2-api PR #288 (SBDEV-3198 step 4) at commit 67241727 — verifying the round-1 fix commit
lane: code review round 2 (independent — this lane did not author the PR or the round-1 fixes)
reviewed: 2026-09-03
base: 680f1f15 (PR #288 as originally submitted — the round-1 review's head)
head: 67241727 (round-1 fix commit)
worktree: /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-288-review-round2-code
---

# PR #288 — independent code review, round 2

## Verdict

**MERGE-READY, after two javadoc corrections.** All eleven round-1 findings that were claimed fixed
are genuinely fixed, and I proved nine of them by hand-mutating the production code and watching the
new tests go red — including both of H-2's unlock paths, which is the specific failure the round-1
review paid for. I actively tried to break the new per-tenant nesting (hoist mutant, leak sweep,
deadlock analysis, catch-reachability) and could not.

What I did find is that the H-1 fix changed two *observable metric behaviours* that the class
javadoc still describes in its pre-fix form, and both are measurable today:

- **N-1** — the javadoc at `StockSummaryExportJob.java:74-76` still says `skippedLockBusy` is
  "recorded ONCE PER GROUP FIRE". It is now recorded once per *lock-busy tenant*. Measured **2.0**
  for a two-tenant group.
- **N-2** — a fire in which every member tenant finds the one-key lock busy now **advances
  `last_success_epoch_seconds` with zero exports**. Measured: `last_success = 1.788452838E9`,
  `exports = 0`. At `680f1f15` the whole-fire early return made this impossible.

Neither is a logic defect and neither blocks a merge on its own, but N-1 is a *false statement in a
file being merged* and N-2 is an undisclosed monitoring change on the drain-window path the whole
dual-lock exists for — both live in the same javadoc paragraph, so one edit closes both. Plus two
one-line documentation corrections (N-3, N-4) elsewhere.

Counts: **0 High**, **2 Medium** (both new, both documentation/disclosure), **3 Low** (2 new
documentation, 1 pre-existing). **M-3 remains open exactly as the author disclosed** — mitigated in
duration, not in peak, and still not verified live.

## Evidence collected

Toolchain (`mvn` is not on PATH in this environment — a bare `mvn` gives `command not found`, which
records as an ordinary failure): `JAVA_HOME=/home/nampark/.sdkman/candidates/java/21.0.11-ms`,
`PATH=/home/nampark/.sdkman/candidates/maven/current/bin:$JAVA_HOME/bin:$PATH`.

| Instrument | Result |
|---|---|
| `mvn -o clean test` (FULL SUITE) | **6238 run, 0 failures, 0 errors, 67 skipped** — BUILD SUCCESS, 3m32s |
| Targeted: `-Dtest='StockSummaryExportJob*,SchedulingConfigurationUnitTest,SchedulingReconcileIdempotencyUnitTest,WholeRunSuccessGaugeUnitTest,NeverMatcherNullBlindnessArchTest,AdminActionControllerUnitTest,StockCountRestControllerUnitTest,StaleClubBatchCleanupJob*'` | **172 run, 0 failures, 0 errors** |
| **Mutant A** — delete `unlock(STOCK_SUMMARY_EXPORT, tenantId)` from the two-key `finally` (`:273`) | **KILLED** — `throwingTenantReleasesBothLocks:529`, `twoTenantGroupReleasesEachLockTwice:545` |
| **Mutant B** — delete `unlock(STOCK_SUMMARY_EXPORT)` from the one-key `finally` (`:276`) | **KILLED** — `throwingTenantReleasesBothLocks:530`, `twoTenantGroupReleasesEachLockTwice:546` |
| **Mutant H-1** — hoist the one-key acquire/release back out of the loop (whole-fire scope, the exact `680f1f15` shape) | **KILLED** — `busyOneKeySkipsOnlyThatTenant:511`, `twoTenantGroupReleasesEachLockTwice:546` |
| **Mutant M-1** — restore `anyFailure = true; jobMetrics.tenantFailure(...)` in the derivation catch | **KILLED** — `derivationFailureForOneTenantDoesNotFailTheGroup:595` |
| **Mutant M-4** — disable the `runFor` int4-overflow guard (`if (false) try {`) | **KILLED** — `runForSkipsInt4OverflowingTenantWithoutLocking:564` |
| **Mutant M-2** — add `jobMetrics.markLastRun()` to `runForCurrentTenant` | **KILLED** — `doesNotTouchTheWholeRunGauges:429` |
| **Mutant L-1** — drop both `.toLowerCase(Locale.ROOT)` calls | **KILLED** — 13 failures / 7 errors |
| **Mutant L-2** — restore `runForCurrentTenant(); return ok(true);` in `AdminActionController` | **KILLED** — `surfacesRefusalInsteadOfHardcodedSuccess:157` (`expected:<false> but was:<true>`) |
| **Mutant L-4** — relabel staleClub's shortfall ERROR with `StockSummaryExportJob.JOB_NAME` | **KILLED** — `noScheduleTenantIsNamed:1100` (the pre-fix assertion would have passed) |
| **Probe N-1/N-2** — temporary test: 2 active member tenants, one-key `tryLock` always `false` | `skipped_lock_busy=2.0`, `last_success=1.788452838E9`, `exports=0` |
| One-key/two-key co-holder sweep `grep -rn "tryLock(AdvisoryLockService.JobLockId\." src/main` | 10 sites across 8 jobs; `StockSummaryExportJob` is the **only** dual-form holder (`:244` + `:252`) |
| `grep -rn "stays held throughout\|once per invocation\|whole trigger fire\|ONCE PER GROUP FIRE" src/` | 6 hits — `AdvisoryLockService.java:40-41` and `StockSummaryExportJob.java:75` are stale (N-1, N-3) |
| `grep -n "maximum-pool-size" src/main/resources/application.properties` | `:66 landlord.datasource.maximum-pool-size=2` — unchanged, M-3 still open |

Worktree restored to a clean `67241727` after every mutant (`git status --porcelain` empty, verified
between runs and at the end). Every mutant was applied to **one** file at a time and reverted with
`git checkout --` before the next.

---

## Round-1 findings — verification

### H-1 (High) — one-key lock scoped to the whole fire → **RESOLVED**

`StockSummaryExportJob.java:244-277`. The nesting is now, per matching tenant, exactly:

```
:244  if (!tryLock(STOCK_SUMMARY_EXPORT)) { LOG.warn(...); skippedLockBusy(); continue; }
:251  try {
:252      if (!tryLock(STOCK_SUMMARY_EXPORT, tenantId)) { LOG.debug(...); continue; }
:257      tenantSample = startTenantTimer();
:258      try { ...activation gate... exportStockSummary(tenantName); ... }
:272      finally { unlock(STOCK_SUMMARY_EXPORT, tenantId); }
:275  } finally { unlock(STOCK_SUMMARY_EXPORT); }
```

I verified four separate properties rather than reading the shape and accepting it:

1. **It really is per-tenant, not once.** The hoist mutant — restoring the literal `680f1f15`
   structure (acquire before the loop, `return` on busy, release after) — was killed by two tests.
2. **No acquire/release gap.** There is nothing between `tryLock` returning true at `:244` and the
   `try {` at `:251`, so the one-key lock cannot be acquired and then leaked past the `finally`.
3. **Every exit from the inner block passes the one-key `finally`.** The two-key-busy `continue`
   (`:255`), the not-activated `continue` (`:265`), a throwing `exportStockSummary`, and normal
   completion all unwind through `:275`. Confirmed by `throwingTenantReleasesBothLocks`, which
   asserts *both* unlocks on the throw path.
4. **No new deadlock path.** `pg_try_advisory_lock` is non-blocking (`AdvisoryLockService.java:74-80`
   returns the boolean, never waits), and the one-key form is released before the next iteration
   acquires it, so `AdvisoryLockService`'s "never nest two locks of the SAME form" rule is not
   violated at any point. Two converted replicas can only ever `false` each other out, never block.

The log was also raised `LOG.debug` → `LOG.warn` (`:245`) as the round-1 fix recommended.

### H-2 (High) — both `runFor` unlock paths unpinned → **RESOLVED**

This is the finding I was most sceptical of, because reading a test that *looks* like it pins an
unlock proves nothing. I deleted each `unlock` call site individually and re-ran. Both mutants died,
each to the same two tests:

- `StockSummaryExportJobTest$DualLockPerTenantScoping.throwingTenantReleasesBothLocks` — single
  tenant whose `streamStockCount` throws; asserts `unlock(ID, 1L)` **and** `unlock(ID)`.
- `StockSummaryExportJobTest$DualLockPerTenantScoping.twoTenantGroupReleasesEachLockTwice` — two
  tenants; asserts `times(2)` on both forms.

The `times(2)` pin is what makes the pair strong: it kills both "unlock deleted" and "unlock hoisted
out of the loop" with one assertion. Round-1's measured survival (124 tests green with either
deletion) is genuinely closed.

### M-1 (Medium) — pre-membership derivation failure charged a `tenantFailure` → **RESOLVED**

`:211-219` now wraps `deriveSpecForCurrentTenant()` in its own `try`, whose catch sets **only**
`anyReadFailure` and `continue`s. The outer catch (`:278-284`) keeps `anyFailure` + `tenantFailure`.

I checked the two things that could have gone wrong here:

- **Is the outer catch really post-membership-only now?** Yes. Everything between `anyMember = true`
  (`:223`) and the outer catch is post-membership; the only pre-membership statements inside the
  outer `try` are `TenantContext.setCurrentTenant(profile)` (`:204`, a `ThreadLocal` set) and the
  derivation, which now has its own catch. So the comment at `:279-280` is accurate.
- **Did the split accidentally swallow real export failures?** No — that was the specific risk. The
  pre-existing `StockSummaryExportJobMetricsUnitTest$TenantBodyThrows
  .tenantBodyThrows_incrementsFailureWithReasonTag` still passes, asserting
  `wms2.cron.stock_summary_export.failure{tenant=tenant1,reason=RuntimeException} == 1.0` when
  `streamStockCount` throws. A `throw` from `exportStockSummary` still reaches the OUTER catch.

Mutant M-1 (restoring the pre-fix `anyFailure`/`tenantFailure` in the derivation catch) was killed
by `derivationFailureForOneTenantDoesNotFailTheGroup`, which asserts `last_success_epoch_seconds > 0`
over a fixture where tenant1's zone lookup throws and tenant2 exports cleanly.

**One nit, filed below as N-4:** the fix's own comment claims it mirrors `StaleClubBatchCleanupJob`
"exactly". It does not — StaleClub has no derivation-scoped catch at all.

### M-2 (Medium) — "preserved EXACTLY" was false → **RESOLVED**

The javadoc at `:306-338` no longer says "EXACTLY". It now enumerates the two deliberate departures
(the two-key lock widening, and the dropped whole-run gauges) and gives the reasoning for the second
— "folding a manual single-tenant run now into those same fleet gauges would make fleet-health
alerting go green off an admin clicking a button". That is the right call and it is now written down.

More importantly it is *pinned*: `doesNotTouchTheWholeRunGauges` asserts all four —
`last_run_epoch_seconds == 0`, `last_success_epoch_seconds == 0`, no `skipped_lock_busy` counter, no
`duration` timer — against a locally-constructed `JobMetrics`. Mutant M-2 (adding a single
`markLastRun()` call to `runForCurrentTenant`) was killed by it.

### M-3 (Medium) — dual-lock doubles landlord-pool holdings against an in-repo cap of 2 → **STILL OPEN, correctly disclosed**

`src/main/resources/application.properties:66` still reads `landlord.datasource.maximum-pool-size=2`,
and there is no live pool-cap reading anywhere in the PR. The author's characterisation
("substantially mitigated, not resolved") is accurate and I want to state the mitigation precisely so
it is not over-read:

- **Peak is unchanged.** During any member tenant's export the job still holds **2 of 2** landlord
  connections (one-key at `:244` + two-key at `:252`).
- **Duration is reduced.** The 2-of-2 hold now spans one tenant's export instead of the entire
  per-tenant walk, and drops to **zero** held connections between tenants — so other jobs' `tryLock`
  calls get a window every tenant boundary instead of none for the whole night.

That is a genuine improvement to the starvation window the round-1 M-3 described, but a single
tenant's full-inventory export is itself a long operation, so "other jobs starve for minutes at a
time" is still reachable if the running cap really is 2. The verification the round-1 review asked
for (`hikaricp.connections.max` off the actuator, or `pg_stat_activity` under a held lock) has not
been done — DB/actuator MCP servers all failed to connect this session too (12 `CONNECT_TIMEOUT`s),
so I could not do it either. **Carry this forward as an operator task, not a code change.**

### M-4 (Medium) — two regressions from step 3's reviewed form → **RESOLVED (both)**

`:227-238`. Compared line-by-line against `StaleClubBatchCleanupJob.java:167-186`:

1. `int objId = Math.toIntExact(tenantId); LOG.trace(...)` — the narrowed value is assigned and used,
   matching step 3's L-2 form. The bare discarded call is gone.
2. The `anyReadFailure = true` dead store in the `ArithmeticException` catch is gone, and the comment
   at `:228-230` records *why* (`anyMember` is already true, so the only reader is unreachable) —
   which is step 3's L-3 reasoning, carried across correctly.

The missing `runFor`-level int4 test also landed:
`runForSkipsInt4OverflowingTenantWithoutLocking` puts `Integer.MAX_VALUE + 1` on a second tenant and
asserts `never()).tryLock(ID, overflowing.getId())` plus `times(1)` on the export. Mutant M-4
(`if (false) try {`, neutering the guard) killed it. The guard is now observable, so the "latent
removal waiting for a cleanup pass" risk round-1 named is closed.

### L-1 (Low) — case-sensitive tenant lookup → **RESOLVED**

`:345-347` lower-cases both arguments with `Locale.ROOT` (`Locale` arrives via the existing
`java.util.*` import; compiles clean). The javadoc at `:329-333` explains the reasoning without
overclaiming ("lower-case in every known environment, but the lookup does not rely on that holding
forever").

This one is pinned as a side effect rather than by a dedicated test, but it *is* pinned: the three
fixtures' repository stubs were changed to expect the lower-cased arguments (`"wh01"`, `"wh02"`)
while their `TenantProfile`s still carry `"WH01"`/`"WH02"`. Mutant L-1 (removing both
`toLowerCase` calls) produced **13 failures and 7 errors** — the stub no longer matches, so
`STRICT_STUBS` fires `PotentialStubbingProblem`/`UnnecessaryStubbing` across the class. Blunt, but
unambiguous: the lowercasing cannot be removed silently.

### L-2 (Low) — `triggerUpdateStock` returned a hard-coded `true` → **RESOLVED**

`runForCurrentTenant()` is now `boolean` (`:339`) and returns `false` on all four refusal paths
(no context `:343`, no landlord row `:351`, int4 overflow `:359`, lock-busy `:364`) plus the
export-threw path (`:371`); `AdminActionController.java:121-122` surfaces it.

**I checked the cross-caller risk the task flagged specifically.**
`StockCountRestController.java:110-112` is:

```java
public Runnable triggerSchedule() {
    return stockSummaryExportJob::runForCurrentTenant;
}
```

A method reference whose result is discarded is compatible with a `void` functional interface, so
this still compiles and behaves identically — confirmed empirically, not just by language-rule
recall: `StockCountRestControllerUnitTest` (`TriggerSchedule`, `TriggerStockCount`, `GetStockCount`
— 5 tests) passes at head. No other caller exists (`grep -rn "runForCurrentTenant" src/main` → 3
hits: the declaration and the two callers).

Mutant L-2 (reverting the controller to the hard-coded `true`) was killed by the new
`surfacesRefusalInsteadOfHardcodedSuccess` test with the exact diagnostic
`Response content expected:<false> but was:<true>`. Four `runForCurrentTenant` unit tests also gained
`assertThat(ran).isFalse()` / `.isTrue()` assertions, so the return value is pinned at the source as
well as at the endpoint.

### L-3 (Low) — stale comment in `configureAllTasks` → **RESOLVED**

`SchedulingConfiguration.java:630-636` now says "The two D′ grouped jobs" and "the four
single-trigger reads below". I re-derived both counts from the code directly rather than trusting
the comment: `:637-638` are the two grouped calls (`configureStaleClubBatchCleanupGroups`,
`configureStockSummaryExportGroups`); `:639-646` are four `onlyIfMissing` calls
(`cleanUpOldMessages`, `orderRelease`, `replenish`, `releaseExpiredPickingOrdersFromUser`).
**Two and four.** Correct. The `@DisplayName` on `callerContextIsRestored` was corrected from "five"
to "four" in the same pass.

### L-4 (Low) — `noScheduleTenantIsNamed` did not name the job → **RESOLVED**

The assertion now chains `.contains("staleClubBatchCleanup")` before the message text
(`SchedulingConfigurationUnitTest.java:1096-1100`). The two shortfall log sites are byte-identical
apart from the `JOB_NAME` argument — `SchedulingConfiguration.java:810-811` (stockSummaryExport) and
`:976-977` (staleClubBatchCleanup) — so this is exactly the substitutability the finding named.

I mutation-checked the *added clause specifically*, which matters because a naive mutant (deleting
staleClub's log entirely) would have been killed by the old assertion too and proved nothing. Instead
I swapped staleClub's site to log `StockSummaryExportJob.JOB_NAME`: the new assertion **fails**
(`noScheduleTenantIsNamed:1100`) where the round-1 assertion would have passed. The added clause is
load-bearing.

### L-5 (Low) — migrated fixtures gained an unexplained `TenantContext` → **RESOLVED**

`StockSummaryExportJobOmsDecouplingTest.java:57-64` gained a class-javadoc paragraph that says both
why the context is now needed (`runForCurrentTenant()` resolves it) *and* the subtle part the
round-1 finding was actually about — that `TenantAwareTaskDecorator`'s behaviour differs between a
null and a non-null context, so the thread-identity assertion depends on the fixture staying
context-bearing.

`StockSummaryExportJobBulkInsertTest.java:76-77` already carried an explanatory comment from
`680f1f15` ("SBDEV-3198 D′: `runForCurrentTenant()` … resolves the caller's `tenant_db_configuration`
row"), which covers it. No gap.

---

## New findings

### N-1 (Medium) — the class javadoc's "recorded ONCE PER GROUP FIRE" is now FALSE for `skippedLockBusy`, and nothing pins the new per-tenant count

`StockSummaryExportJob.java:74-76`:

> `JobMetrics`' five whole-run gauges (`markLastRun`, `recordDuration`, `skippedLockBusy`, and
> per-run `markLastSuccess`) are recorded **ONCE PER GROUP FIRE** in `runFor` …

The H-1 fix moved `jobMetrics.skippedLockBusy()` from the whole-fire early-return path (`:180` at
`680f1f15`) into the per-tenant loop (`:248`). It is now recorded **once per lock-busy member
tenant**. This paragraph was verified as accurate by the round-1 review ("Claim #3 (per-group
metrics) … All five whole-run writes are once per group fire and nowhere else"); the fix invalidated
it and the paragraph was not updated.

Measured, not inferred — temporary probe test, two active member tenants, one-key `tryLock` stubbed
`false`:

```
PROBE skipped_lock_busy=2.0
```

Consequence: `wms2.cron.stock_summary_export.skipped_lock_busy` changes meaning from "this group fire
was blocked" to "this many tenant-occurrences were blocked", and its rate during a drain window
scales with N×G rather than G. An operator with an existing threshold on that counter will see it
move for a reason the javadoc denies is possible.

Nothing pins the new semantics either.
`StockSummaryExportJobMetricsUnitTest.tryLockBusy_incrementsSkippedLockBusyCounter` was updated to
supply one active tenant and still asserts `== 1.0` — with a single tenant, per-fire and per-tenant
are indistinguishable, so that test would stay green if the increment were hoisted back out.

**Fix:** correct `:74-76` to say `skippedLockBusy` is per lock-busy *tenant* while the other three
remain per fire, and add a two-tenant assertion (`== 2.0`) to the metrics test so the distinction is
observable.

### N-2 (Medium) — a fire in which EVERY member tenant is one-key-busy now advances `last_success_epoch_seconds` with zero exports

`StockSummaryExportJob.java:248-249` + `:299`.

At `680f1f15` a busy one-key returned at `:181`, *before* the `try` — so `markLastSuccess()` was
unreachable and the freshness gauge went stale, which is what alerting is for. After the H-1 fix the
busy path `continue`s, `anyMember` is already `true` (`:223`), `anyFailure` stays `false`, and
`:299` `if (!anyFailure) jobMetrics.markLastSuccess();` fires.

Same probe, same run:

```
PROBE last_success=1.788452838E9
PROBE exports=0
```

The gauge advanced on a fire that exported nothing for anyone.

I want to be fair about severity, because there is a real argument the new behaviour is *correct*:
a busy one-key means an old-code replica holds `100004L` and **is** exporting. So "something
exported" is true fleet-wide. But two things make it worth writing down:

- The old-code replica is exporting on the **pre-D′ single schedule** — one arbitrary tenant's hour
  applied to the whole fleet, which is the §1.1 symptom this ticket exists to fix. So during the
  drain window `last_success` now reads healthy while the fleet is demonstrably on the broken
  schedule; before the fix, the gauge went stale and an operator would have looked.
- It is a behaviour change on the exact path the transitional dual-lock was added for, it is
  undisclosed in both the class javadoc and `runFor`'s javadoc, and **no test pins it either way** —
  a future "restore the early return" edit would be green.

This is one release's exposure, so it is a disclosure-and-pin item, not a redesign. It lives in the
same javadoc paragraph as N-1, so one edit covers both.

**Fix:** state it in the `:74-80` paragraph (the AC6 tradeoff paragraph already discusses exactly
this gauge, so it belongs there), and add a `runFor` test asserting the gauge behaviour for an
all-busy group — whichever direction is intended.

### N-3 (Low) — `AdvisoryLockService`'s class javadoc still normatively describes the hoisted shape that no longer exists

`src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java:39-41`:

> … this is required by SBDEV-3198's dual-lock rolling-deploy transition (§7a step 4): a converting
> release takes the one-key job-wide lock **once per invocation**, then per-tenant takes/releases the
> two-key lock **while the one-key lock stays held throughout**.

That is a precise description of `680f1f15` and it is now wrong. `StockSummaryExportJob` is the sole
dual-form holder in `src/main` — derived by `grep -rn "tryLock(AdvisoryLockService.JobLockId\." src/main`,
which returns 10 sites across 8 jobs, of which only `StockSummaryExportJob.java:244` and `:252` are a
one-key/two-key pair on one thread (the other seven jobs take a single form each). So the shape this
paragraph documents has **zero** implementations.

This matters more than an ordinary stale comment because it is the *normative* document for the
"never nest two locks of the same form" rule, sits next to the two `ThreadLocal` slot declarations
that implement it, and is what step 5 will be read against when four more jobs are converted.

This is the sibling the fix pass missed: the H-1 fix updated `StockSummaryExportJob`'s own javadoc in
three places but not the service javadoc describing the same contract.

**Fix:** one sentence — "takes/releases the one-key lock around each tenant's two-key lock, so the
two forms are held simultaneously for one tenant's critical section at a time."

### N-4 (Low) — the M-1 fix comment claims it mirrors `StaleClubBatchCleanupJob` "exactly"; it does not

`StockSummaryExportJob.java:206-210`:

> `// M-1 (PR #288 review): derivation failures are PRE-membership — they must set only`
> `// anyReadFailure, never anyFailure/tenantFailure, mirroring StaleClubBatchCleanupJob#runFor`
> `// exactly (§7a step 3 review).`

`StaleClubBatchCleanupJob.runFor` has **no** derivation-scoped `try/catch` (verified by reading
`StaleClubBatchCleanupJob.java:152-215`): it calls `deriveSpecForCurrentTenant()` bare at `:156` and
relies on one broad catch at `:198` whose comment explicitly calls itself *"Conservative"*. The
*outcome* matches (neither charges a `tenantFailure` for a derivation failure) — but only because
StaleClub has no `JobMetrics` at all, so it has no `tenantFailure` to charge.

So the new structure is **better** than the reference, not a mirror of it. The word "exactly" is the
same overclaim shape the round-1 review flagged as M-2, reintroduced one paragraph away from the fix
for it. `runFor`'s own javadoc at `:168-170` gets this right — it enumerates three specific things it
mirrors, all of which genuinely do.

**Fix:** say "achieving the same outcome as `StaleClubBatchCleanupJob#runFor`, which relies on a
single conservative catch because it has no per-tenant metrics to mis-charge."

### N-5 (Low, pre-existing — NOT introduced by this round) — `startTenantTimer()` sits between the two-key acquire and its `try`

`StockSummaryExportJob.java:252-258`: `tenantSample = jobMetrics.startTenantTimer();` (`:257`) is
after the two-key `tryLock` succeeds but before the `try {` (`:258`) whose `finally` releases it. A
throw from `startTenantTimer()` would leak the two-key lock — the outer `finally` at `:275` releases
only the one-key form.

I checked the `680f1f15` original before filing this and the placement is byte-identical there
(`git show 680f1f15:…` lines 224-229), so **this is pre-existing, not a regression from the fix**.
It is also not reachable in practice (`Timer.start(registry)` does not throw). Noting it only because
the per-tenant one-key `finally` now sits right beside it and invites the comparison; step 5 should
move the assignment inside the `try` when it clones this pattern.

### N-6 (informational) — the claimed full-suite count is off by one

Claimed: **6237**/0/67. Measured: **6238**/0/67 (`mvn -o clean test`, BUILD SUCCESS, 3m32s).

The arithmetic reconciles against the stated pre-round baseline: 6230 + 8 new tests = 6238. The eight
are five in `StockSummaryExportJobTest$DualLockPerTenantScoping`, two in
`StockSummaryExportJobUnitTest$RunForCurrentTenantLocking`
(`returnsFalseAndStillUnlocksWhenExportThrows`, `doesNotTouchTheWholeRunGauges`), and one in
`AdminActionControllerUnitTest$TriggerUpdateStock` (`surfacesRefusalInsteadOfHardcodedSuccess`).

No test was lost and nothing is red — this is a transcription slip in the claim, not a defect. Flagged
only because "0 failures" claims are load-bearing here and the count is the thing that would reveal a
silently-dropped test.

---

## Verified — things I tried to break and could not

**The per-tenant nesting has no leak or gap.** I enumerated every control-flow exit between the
one-key acquire (`:244`) and its `finally` (`:275`): the two-key-busy `continue` (`:255`), the
not-activated `continue` (`:265`), an `exportStockSummary` throw, and normal fall-through. All four
unwind through `:275`. There is no statement between `tryLock` returning true and the `try {`. The
two hand-deletion mutants confirm the `finally` bodies are the only release sites and that both are
observed.

**No new deadlock is reachable.** `AdvisoryLockService.tryLock` uses `pg_try_advisory_lock`
(`:74-80`) — non-blocking, returns `false` rather than waiting. Two converted replicas contending on
the per-tenant one-key can only skip each other. The same form is never nested on one thread: the
one-key is released at the end of each iteration before the next iteration acquires it.

**Moving the int4 guard did not change any other branch's reachability.** The guard sits at `:226-238`
between `anyMember = true` (`:223`) and the one-key acquire (`:244`), so its `continue` skips both
lock forms — which is what `runForSkipsInt4OverflowingTenantWithoutLocking` asserts, and what the
mutant proved is load-bearing. The catch is still narrowly scoped to the `toIntExact` statement, so
an `ArithmeticException` from `exportStockSummary`'s own arithmetic still reaches the outer catch and
is correctly reported as a generic tenant failure — the property step 3's L-4 comment protects.

**The M-1 split does not swallow work failures.** The outer catch remains the handler for
`exportStockSummary` throws, proven by the untouched pre-existing
`tenantBodyThrows_incrementsFailureWithReasonTag` (asserts the tagged `failure` counter and
`last_run > 0`) passing at head, and by `throwingTenantReleasesBothLocks` reaching both unlocks.

**The `boolean` return did not break the `Runnable` caller.** `StockCountRestController`'s
`stockSummaryExportJob::runForCurrentTenant` still compiles and behaves identically (result
discarded); its 5 tests pass.

**The `WholeRunSuccessGaugeUnitTest` edit removed a stub, not an assertion.** The deleted
`when(tryLock(STOCK_SUMMARY_EXPORT)).thenReturn(true)` in
`noActiveTenants_currentlyReportsSuccessWithoutRunningAnything` became an `UnnecessaryStubbing` under
`STRICT_STUBS` once the empty-fleet path returns before any lock attempt. No assertion was weakened;
the test's `markLastSuccess` pins are untouched.

**No `never()`-matcher regression.** `NeverMatcherNullBlindnessArchTest` (4 tests) passes unchanged —
the new `never()` uses concrete `long` arguments, not widened `anyLong()`, so no inventory bump was
needed and none was made.

---

## Recommended pre-merge set

1. **N-1 + N-2** — one edit to the `StockSummaryExportJob` class javadoc at `:74-80`: `skippedLockBusy`
   is now per lock-busy tenant, and an all-busy fire advances `last_success`. Optionally add the
   two-tenant `skipped_lock_busy == 2.0` assertion so N-1 is pinned as well as documented.
2. **N-3** — one sentence in `AdvisoryLockService.java:39-41`.
3. **N-4** — soften "mirroring … exactly" at `StockSummaryExportJob.java:206-210`.
4. **N-5** — leave as-is for this PR (pre-existing); fold into step 5's clone.
5. **M-3** — unchanged from round 1: read the running landlord `maximumPoolSize` before the step-5
   fan-out. Not a merge blocker for this PR given the duration mitigation, but it should not stay
   open past step 5, which multiplies the number of jobs holding two forms.

Nothing here disputes the design, and nothing here is a logic defect. Both round-1 Highs are
genuinely dead — I killed the mutants that round 1 measured as survivors.
