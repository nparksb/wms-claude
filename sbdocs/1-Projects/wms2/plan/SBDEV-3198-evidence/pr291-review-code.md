---
name: pr291-review-code
description: Independent code review of wms2-api PR #291 (SBDEV-3198 step 5 part 1/4, CleanUpOldMessagesJob → D′) at commit 55ec08e1
lane: code review (independent — this lane did not author the PR)
reviewed: 2026-09-03
base: f440b534 (develop tip, post-#288 merge)
head: 55ec08e1
worktree: /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-291-review-code
---

# PR #291 — independent code review

## Verdict

**FIX BEFORE MERGE — one test, plus one decision that is now overdue.**

This is a materially better-prepared PR than #288 was at submission. The two gaps the authoring
session says it found and fixed by PIT before opening are **genuinely fixed** — I deleted both of
`runFor`'s unlock calls and flipped all five of `runForCurrentTenant`'s refusal returns, and every
one of those seven mutants was killed. The `runFor` structure is not merely "similar" to the
reviewed `StockSummaryExportJob` shape, it is the same shape line-for-line, and
`configureCleanUpOldMessagesGroups` is **byte-identical** to its sibling modulo identifiers (proved
by a normalized diff, below — not by reading). The full suite reproduces the claimed
6250/0/67 exactly.

What it missed is the *third* thing step 4's review paid for on this same method and which this PR's
own javadoc asserts normatively: **`runForCurrentTenant()`'s "the whole-run `JobMetrics` gauges are
deliberately NOT recorded here" is completely unpinned.** I added `markLastRun()` +
`recordDuration()` back into that method and ran the **entire** suite: `6250 run, 0 failures, 0
errors`, BUILD SUCCESS. Step 4 has `doesNotTouchTheWholeRunGauges` for exactly this; the PR body
claims the new nested class "mirrors `StockSummaryExportJobUnitTest`'s", and it mirrors five of its
six tests. That is a one-test fix.

Separately, PR #288's round-2 review closed with an explicit, dated instruction: *"M-3 — read the
running landlord `maximumPoolSize` **before the step-5 fan-out**. … it should not stay open past step
5, which multiplies the number of jobs holding two forms."* PR #291 **is** the step-5 fan-out, it
adds the second dual-form holder against an in-repo cap of 2, and no pool reading appears anywhere in
the PR. That is not a code defect — but it is a deadline this PR crosses silently, and this
particular job makes it worse than step 4 did (§M-2).

Counts: **0 High**, **2 Medium**, **4 Low**, **1 informational**.

## Evidence collected

| Instrument | Result |
|---|---|
| `mvn -o clean test` (full suite, HEAD) | **6250 run, 0 failures, 0 errors, 67 skipped** — BUILD SUCCESS, 3m28s. Matches the PR's claim exactly |
| `mvn -o test -Dtest='CleanUpOldMessagesJob*,SchedulingConfigurationUnitTest,SchedulingReconcileIdempotencyUnitTest,WholeRunSuccessGaugeUnitTest,NeverMatcherNullBlindnessArchTest,AdminActionControllerUnitTest,AdminTriggerTenantScopeUnitTest,StockCountRestControllerUnitTest,StaleClubBatchCleanupJob*,StockSummaryExportJob*'` | **217 run, 0 failures, 0 errors, 2 skipped** — BUILD SUCCESS |
| Hand mutant **A** — delete `unlock(CLEAN_UP_MESSAGES, tenantId)` from the per-tenant `finally` (`:209`) | **KILLED** — 70 run, **2 failures** |
| Hand mutant **B** — delete `unlock(CLEAN_UP_MESSAGES)` from the one-key `finally` (`:212`) | **KILLED** — 70 run, **2 failures** |
| Hand mutant **C** — no-landlord-row refusal `return false` → `return true` (`:282`) | **KILLED** — 1 failure |
| Hand mutant **D** — int4-overflow refusal `return false` → `return true` (`:290`) | **KILLED** — 1 failure |
| Hand mutant **E** — lock-busy refusal `return false` → `return true` (`:295`) | **KILLED** — 1 failure |
| Hand mutant **F** — archive-threw `return false` → `return true` (`:302`) | **KILLED** — 1 failure |
| Hand mutant **G** — no-`TenantContext` refusal `return false` → `return true` (`:274`) | **KILLED** — 1 failure |
| Hand mutant **H** — add `jobMetrics.markLastRun()` + `recordDuration()` into `runForCurrentTenant` | **SURVIVED the FULL suite** — 6250/0/0/67, BUILD SUCCESS. See M-1 |
| Hand mutant **I** — revert `AdminActionController` to `ok(true)` with the return discarded | **KILLED** — 1 failure |
| Hand mutant **J** — delete `jobMetrics.skippedLockBusy()` from the busy-one-key branch (`:184`) | **KILLED** — 1 failure |
| Normalized structural diff, `configureCleanUpOldMessagesGroups` (`:697-786`) vs `configureStockSummaryExportGroups` (`:844-933`), identifiers substituted | **Zero differences** except the log label string. Genuine parity, not approximate |
| `grep -rn "cleanUpOldMessagesJob\.\|CleanUpOldMessagesJob" src/main` | 2 production callers only — `SchedulingConfiguration` (`runFor`, `deriveSpecForCurrentTenant`) and `AdminActionController:131` (`runForCurrentTenant`). No caller missed |
| `grep -rn "tryLock(AdvisoryLockService.JobLockId\." src/main` | 12 sites / 8 jobs; **two** are now one-key/two-key pairs on one thread (`CleanUpOldMessagesJob:180+188`, `StockSummaryExportJob:266+274`) — was one. See M-2 |
| `V2.2.20__authorization_join_table_primary_keys.sql:353-360` + `V2.2.00__base_v2_schema.sql:1416-1434` | `message_archived` genuinely has **no** PK and no unique constraint — 18 plain columns, `id bigint` nullable. Premise confirmed; see L-2 for what else that comment says |
| `never()`-with-primitive-matcher site count, counted by hand from `grep -n "never()"` | `AdminTriggerTenantScopeUnitTest` = 1 site × 2 `anyLong()` = **2** ✔; `CleanUpOldMessagesJobUnitTest` = 2 sites × 2 = **4** ✔; `CleanUpOldMessagesJobTest` = **0** ✔. Census arithmetic in the source is right; the PR body's is not (L-3) |
| Trigger-count arithmetic, re-derived independently from `configureAllTasks` | `+3`, `+2`, `+2`, `cancelled == 2` — all four correct (see Verified) |

Worktree restored to a clean `55ec08e1` after every mutation (`git status --porcelain` empty, checked
after each pair and at the end).

---

## M-1 (Medium) — `runForCurrentTenant()`'s "deliberately NOT recorded" metrics claim is asserted in the javadoc and pinned by nothing; a mutant that reverses it survives the entire 6250-test suite

`src/main/java/net/aim_ai/wms/schedulejob/CleanUpOldMessagesJob.java:252-257`

> *"**The whole-run `JobMetrics` gauges are deliberately NOT recorded here** —
> `markLastRun`/`recordDuration`/`skippedLockBusy` describe a scheduled `runFor` FIRE. Folding a
> manual single-tenant "run now" into those same fleet gauges would make fleet-health alerting go
> green off an admin clicking a button…"*

That is a normative claim about observable behaviour on a shipped endpoint
(`GET /v3/adminAction/triggerArchiveMessages`), and it is the *documented* behaviour change relative
to the deleted `doCalculation(false)` — which did record all three, via the shared `finally` at the
old `:126-128` (`git show f440b534:…CleanUpOldMessagesJob.java`). Nothing observes it.

Measured, not inferred. I inserted into `runForCurrentTenant`'s `try` block:

```java
jobMetrics.markLastRun();
jobMetrics.recordDuration(1L);
```

and ran the **whole** suite, not a subset:

```
[WARNING] Tests run: 6250, Failures: 0, Errors: 0, Skipped: 67
[INFO] BUILD SUCCESS
```

This is not a novel finding — it is step 4's **M-2**, which PR #288's review round 1 raised and whose
fix round 2 verified as `StockSummaryExportJobUnitTest.RunForCurrentTenantLocking
#doesNotTouchTheWholeRunGauges`. `grep -rn "doesNotTouchTheWholeRunGauges" src/test` returns
**one** hit, in `StockSummaryExportJobUnitTest`. The step-5 clone has five of that class's six tests.

The PR body says the new nested class *"mirror[s] `StockSummaryExportJobUnitTest`'s"* and that
`runForCurrentTenant` *"deliberately drops all `JobMetrics` calls, mirroring step 4's M-2 decision
exactly"*. The decision is mirrored; the pin that makes the decision survive contact with a future
editor is not. And step 4's javadoc is explicit that the pin is the point — it ends *"Kept as-is
deliberately, not restored — pinned by …#doesNotTouchTheWholeRunGauges."* PR #291's javadoc makes the
same claim and names no pin, because there is none.

This matters concretely because the reversal is *attractive*: a reader who notices that a manual
trigger records no duration and no last-run is one plausible "fix the missing metrics" commit away
from silently re-arming the exact failure mode the javadoc warns about (an admin button press
refreshing a fleet freshness gauge). Nothing would go red.

Note the tests here cannot use the step-4 assertion form as-is: `RunForCurrentTenantLocking`
constructs a **real** `JobMetrics(new SimpleMeterRegistry(), "clean_up_old_messages")`
(`CleanUpOldMessagesJobUnitTest:134-136`), so `verify(jobMetrics, never())` is unavailable. Either
inject a mock `JobMetrics` for that one test, or assert on the registry —
`assertThat(registry.timer("wms2.cron.clean_up_old_messages.duration").count()).isZero()` — which is
the shape `CleanUpOldMessagesJobMetricsUnitTest` already uses.

**Fix:** one test, mutation-checked with mutant H above.

## M-2 (Medium) — this PR is the "step-5 fan-out" that round 2 named as M-3's deadline; it adds the second dual-form lock holder against `maximum-pool-size=2`, and this job's critical section is unbounded and contains deliberate sleeps

`CleanUpOldMessagesJob.java:180` + `:188` held simultaneously; `application.properties:66`

PR #288's round-2 review closed with (`pr288-review2-code.md:466-468`):

> **M-3** — unchanged from round 1: read the running landlord `maximumPoolSize` **before the step-5
> fan-out**. Not a merge blocker for this PR given the duration mitigation, but it should not stay
> open past step 5, which multiplies the number of jobs holding two forms.

PR #291 is step 5 part 1 of 4. `grep -n "maximum-pool-size" src/main/resources/application.properties`
still returns `:66 landlord.datasource.maximum-pool-size=2`, unchanged, and neither the PR
description nor the plan records a reading from a running environment. The deadline was crossed
without a decision being recorded either way.

Three things make the exposure materially worse here than it was at step 4, and none of them are in
the PR's own account:

1. **There are now two dual-form holders, not one.** `grep -rn "tryLock(AdvisoryLockService.JobLockId\."
   src/main` returns 12 sites across 8 jobs; exactly two of them are one-key/two-key pairs on one
   thread — `StockSummaryExportJob:266+274` and, new in this PR, `CleanUpOldMessagesJob:180+188`.
   `AdvisoryLockService` pins one raw `landlordDataSource` connection *per held form*, so with a cap
   of 2 a **single** job in its critical section already occupies the whole landlord pool. Two
   grouped jobs whose windows overlap therefore cannot both proceed — and both are nightly with
   tenant-editable `*_TIMER_HOUR` sysprops, so overlap is a configuration away, not a deploy away.
2. **The failure is silent and is actively mislabelled.** `AdvisoryLockService.tryLock` catches
   `SQLException` and returns `false` (`:103-105` one-key, `:205-207` two-key), and Hikari's
   `landlord.datasource.connection-timeout=20000` surfaces pool exhaustion as exactly that. A `false`
   from the one-key call lands on `CleanUpOldMessagesJob:181-184`, which logs *"one-key lock held
   (old-code replica), transitional per the dual-lock deploy note"* and increments
   `skipped_lock_busy`. An operator reading that during a pool-starvation event is told the cause is
   an unconverted replica and that it is transitional. Neither is true, and the message will still
   say it after the transitional window closes.
3. **This job's locked section has no time bound, and holds sleeps by design.** Step 4's export is
   bounded by `OMS_EXPORT_CONSUMER_TIMEOUT_S` (`StockSummaryExportJob:423`, floor 30s) at every
   blocking point. This job's `archiveOldMessages()` → `CleanUpOldMessageJobService.archiveMessage()`
   is an **unbounded** `INSERT INTO message_archived SELECT *` followed by a `do/while` delete loop
   with `sleeper.sleep(sleepMs)` between batches, clamped only to `MAX_SLEEP_MS = 5_000`
   (`CleanUpOldMessageJobService:36, 92-104`), iterating until the qualifying rows are exhausted.
   The 2-of-2 landlord hold therefore lasts as long as one tenant's backlog takes, with deliberate
   idle time inside it.

I could not read the running cap myself: all 12 DB/actuator MCP servers failed to connect this
session (`CONNECT_TIMEOUT`), the same obstacle both #288 review lanes hit.

**Fix:** this is an operator task and a decision, not a code change. Either read
`hikaricp.connections.max` for `LandlordHikariPool` off the dev/UAT actuator (or sample
`pg_stat_activity` under a deliberately held lock) and record the number, or record an explicit
decision to carry M-3 through the remaining three step-5 jobs with the risk accepted. What should
not happen is a third and fourth dual-form holder landing with the item still merely open. Cheap
independent hardening regardless: change `:181`'s message so it does not assert a cause it cannot
distinguish (`"one-key lock not acquired — an old-code replica holds it, or the landlord pool is
exhausted"`).

## L-1 (Low) — round 2's N-5 was explicitly assigned to "step 5's clone"; this is that clone, and the placement is unchanged

`CleanUpOldMessagesJob.java:193-194`

```java
                        tenantSample = jobMetrics.startTenantTimer();
                        try {
```

`pr288-review2-code.md:387-398` (N-5) filed this as pre-existing and not a #288 regression, and
closed with: *"step 5 should move the assignment inside the `try` when it clones this pattern."* The
clone has it byte-identical: the two-key lock is acquired at `:188`, `startTenantTimer()` runs at
`:193`, and the `try` whose `finally` releases that lock opens at `:194`. A throw from `:193` leaks
the two-key lock — the enclosing `finally` at `:211-213` releases only the one-key form.

Unreachable in practice (`Timer.start(registry)` does not throw), exactly as N-5 said. Recorded
because the instruction named this PR specifically, and because deferring it again means it arrives
in three more jobs. One-line fix: move the assignment to the first statement inside the `try`.

## L-2 (Low) — the dual-lock's central justification cites `V2.2.20`, and `V2.2.20` says the opposite of what the citation is used to prove

`CleanUpOldMessagesJob.java:31-38` (class javadoc), repeated in the PR description

> *"…would silently insert every qualifying row TWICE into `message_archived`, **with no constraint
> to catch it**."* … *"confirmed: `V2.2.20` lists it explicitly as one of six tables without [a
> primary key]"*

The mechanism is real and I verified it independently: `MessageRepository:33-35` is a bare
`INSERT INTO message_archived SELECT * FROM message where created < :refDate` with no `WHERE NOT
EXISTS`, `message_archived` in `V2.2.00__base_v2_schema.sql:1416-1434` is 18 plain columns with a
**nullable** `id bigint` and no constraint of any kind, and two READ-COMMITTED transactions running
that INSERT concurrently for the same tenant do both see the same source rows. Duplicates would
occur. So the dual-lock is a defensible mitigation and I am not disputing the decision.

But the sentence the javadoc cites as *confirmation* reads (`V2.2.20:353-360`):

> `message_archived` is NOT given a primary key … `archiveMessages` is an UNBOUNDED INSERT-SELECT
> while `deleteMessages` is batched in a loop that can exit early … Either path leaves rows archived
> but not deleted, so the next run re-archives them: **that table can ALREADY hold duplicate ids,
> silently.** A PK on `message_archived.id` would convert that into a permanently failing archive job
> on any affected tenant.

That is the reason there is no constraint, and it establishes that duplicate archive rows are a
**known, accepted, already-occurring** property of ordinary single-replica operation — the interrupt
path is still live at `CleanUpOldMessageJobService:98-102`. The concurrency scenario amplifies an
existing tolerated condition; it does not create an unguarded one. Citing the comment for "no
constraint to catch it" while omitting the same comment's "can ALREADY hold duplicate ids" reads as
stronger evidence than it is, and it is the sentence that carries the decision to take the more
expensive of the two available shapes (step 4's dual-lock rather than step 3's).

**Fix:** one clause — acknowledge that the table already tolerates duplicates by design, and state
the justification as *amplification during the drain window* rather than as novel unguarded
corruption. The decision does not change; its stated basis becomes accurate.

## L-3 (Low) — the PR description's `NeverMatcher` census contradicts the census in the code it describes

PR body: *"`NeverMatcherNullBlindnessArchTest` (census: **150→154** across **38→39** classes)"*.

The source (`NeverMatcherNullBlindnessArchTest.java:384-390`) says **148 across 37** → **154 across
39**. The source is right and the body is wrong: 148 + `AdminTriggerTenantScopeUnitTest:2` +
`CleanUpOldMessagesJobUnitTest:4` = 154, and 37 + 2 new classes = 39. I counted the two new entries
by hand rather than trusting either — `grep -n "never()"` gives
`AdminTriggerTenantScopeUnitTest:310` (one `tryLock(anyLong(), anyLong())` site = 2 matchers) and
`CleanUpOldMessagesJobUnitTest:164, :184` (two sites = 4), with `CleanUpOldMessagesJobTest`
contributing zero (`:400` passes a concrete `overflowing.getId()`).

Harmless in the code; worth correcting in the body, since a wrong "before" figure is what makes a
future census drift argument unresolvable.

## L-4 (Low) — the class javadoc outsources N-1 and N-2 to a sibling class, and the N-1 behaviour is no better pinned here than it was there

`CleanUpOldMessagesJob.java:57-62`

> *"…see `StockSummaryExportJob`'s javadoc for the full reasoning this mirrors, including the
> `skippedLockBusy`-is-per-tenant-not-per-fire exception (N-1) and the
> all-busy-fire-still-advances-last-success behaviour (N-2)…"*

Both statements are true of this job — I confirmed the call sites (`skippedLockBusy()` at `:184`,
inside the per-tenant loop; `markLastSuccess()` at `:233`, reachable when every member tenant
`continue`d on a busy one-key). But `wms2.cron.clean_up_old_messages.skipped_lock_busy` is its own
counter with its own alert threshold, and an operator investigating *this* metric has no reason to
read another job's javadoc. Round 2 also suggested pinning N-1 with a two-tenant
`skipped_lock_busy == 2.0` assertion; `CleanUpOldMessagesJobMetricsUnitTest
.tryLockBusy_incrementsSkippedLockBusyCounter` uses a **one-tenant** fixture and asserts `1.0`, which
cannot distinguish per-fire from per-tenant accounting. Both are cheap: two sentences of javadoc, and
one extra tenant in that fixture.

## L-5 (informational) — the per-tenant timer's population changed silently

Pre-PR (`f440b534:…:93`), `Timer.Sample tenantSample = jobMetrics.startTenantTimer();` was the first
statement of the loop body and ran for **every** active tenant, with an unconditional
`stopTenantTimer` in the `finally`. Now it is `null` until both locks are acquired (`:150`, `:193`)
and stopped only `if (tenantSample != null)` (`:220`).

So `wms2.cron.clean_up_old_messages.tenant_duration` changes from "time spent per active tenant,
including non-members" to "time spent inside the locked critical section, member tenants only" — a
better metric, and identical to the reviewed step 3/step 4 reference, so this is not a divergence.
Noting it only because it is an unannounced meaning change on a shipped timer, and the class javadoc
enumerates the metric changes it *did* consider disclosure-worthy.

---

## Verified — claims that hold

**The `runFor` structure genuinely matches the reviewed shape, including H-1's per-tenant nesting.**
Read line-by-line against `StockSummaryExportJob:199-326`. The one-key `tryLock` sits at `:180`,
*inside* the tenant loop and *after* the membership check and int4 guard, immediately wrapping the
two-key `tryLock` at `:188`; release order is two-key (`:209`) then one-key (`:212`), each in its own
`finally`. This is the post-review shape, not the whole-fire shape H-1 fixed. It is also *pinned*:
`busyOneKeySkipsOnlyThatTenant` stubs the one-key `tryLock` `(false, true)` over two member tenants
and asserts `archiveMessage()` ran once and `tryLock(one-key)` was called twice — under the whole-fire
shape the one-key call happens once, returns `false`, and nothing runs, so that test fails. The H-1
regression cannot silently return.

**H-2 is genuinely closed — both unlock mutants die.** This is the finding PR #288 shipped and had to
fix, and it is the one I most expected to find repeated. Deleting `unlock(CLEAN_UP_MESSAGES, tenantId)`
from `:209` → 2 failures; deleting `unlock(CLEAN_UP_MESSAGES)` from `:212` → 2 failures. The four
`DualLockPerTenantScoping` tests are real assertions, not decoration.

**All five `runForCurrentTenant` refusal paths are pinned.** Flipping each `return false;` to
`return true;` independently — no-context (`:274`), no-landlord-row (`:282`), int4 overflow (`:290`),
lock-busy (`:295`), archive-threw (`:302`) — each produced exactly 1 failure. The PIT `NO_COVERAGE`
report the PR describes is consistent with what I measured afterwards.

**Step 4's M-1, M-4, L-1 and L-2 fixes are all carried across correctly.**
- *M-1*: `deriveSpecForCurrentTenant()` is wrapped in its own `try` (`:156-163`) that sets only
  `anyReadFailure` and `continue`s, so a non-member tenant's read failure cannot write
  `tenantFailure` or flip `anyFailure`. The outer catch (`:214`) is reachable only post-membership.
- *M-4*: `int objId = Math.toIntExact(tenantId); LOG.trace(...)` (`:171-172`) — the narrowed value is
  assigned and used, not discarded — and the `ArithmeticException` catch does **not** re-set
  `anyReadFailure` (the step-3 L-3 dead store is absent).
- *L-1*: the landlord lookup lower-cases both operands with `Locale.ROOT` (`:277-278`).
- *L-2*: `AdminActionController:131-132` assigns and returns the real boolean; mutant I (revert to
  `ok(true)`) is killed.

**`configureCleanUpOldMessagesGroups` is byte-identical to `configureStockSummaryExportGroups`.**
Not "mirrors" by inspection — proved. I extracted both method bodies (`:697-786` and `:844-933`),
substituted the job identifiers, and diffed: the only difference is the log-label string literal.
That covers the additive-only `reconciling && registrations.containsKey(registryKey)` gate placed
before the `CRON_JOB_SHOW_LOG` read, the `callerContext` save/restore in a `finally`, the
per-tenant `TenantContext.clear()`, the malformed-row skip, the three summary log lines, the
per-group `try/catch` failure isolation, and the M-7 ground-truth
`registeredJobNames().contains(JOB_NAME)` return.

**`configureAllTasks` and its L-3 comment are correctly updated.** Three grouped jobs registered
before three `onlyIfMissing` single-trigger jobs (`:637-648`), with the comment's counts moved from
"two grouped / four single" to "three grouped / three single" — the numbers now match the code, which
was L-3's whole complaint at step 4.

**All four trigger-count assertions re-derived independently and correct** (`EXPECTED_TRIGGER_COUNT = 6`):
- `differentZonesMeanTwoGroups` → `+3` = 9. 3 single-trigger (`orderRelease`, `replenish`,
  `releaseExpiredPickingOrdersFromUser`) + 2 zones × 3 grouped jobs = 9. ✔
- `noScheduleTenantIsNamed` → `+2` = 8. `staleClubNoSchedule` gates only staleClub's stub, costing it
  its LA group: 3 + (1 + 2 + 2) = 8. ✔
- `reconcileFillsOnlyTheGap` → `+2`, and `containsKey` on both
  `stockSummaryExport@0 9 9 * * *@America/Los_Angeles` and the cleanUpOldMessages equivalent —
  both grouped jobs read `timerValue`, staleClub's stub does not. ✔
- `cancelled == 2` — only `orderRelease` and `replenish` still swap; `releaseExpiredPickingOrdersFromUser`
  is hard-coded and all three grouped jobs register additively. ✔ (was 3; `cleanUpOldMessages`
  leaving the single-trigger set is exactly the −1.)

**The transaction boundary is unchanged.** `archiveOldMessages()` is byte-identical to the pre-PR
private method apart from a deleted comment block, and still calls
`cleanUpOldMessageJobService.archiveMessage()`, which drives `MessageCleanupBatchService`'s
`REQUIRES_NEW` per-batch transactions on `tenantTransactionManager`. No `@Transactional` was added to
the job, no propagation changed, and the call site moved only in the sense that it is now inside a
second (two-key) lock. The `TenantContext` restore the old `doCalculation`'s outer `finally` performed
for `AdminActionController.triggerOrderReplenish`'s two-jobs-in-sequence case is correctly *dropped*
rather than lost: `runForCurrentTenant()` never sets or clears the context, so there is nothing to
restore, and `AdminTriggerTenantScopeUnitTest.adminTrigger_leavesTheCallersContextIntact` pins it.

**Caller sweep is complete and no `ok(true)` sibling was missed in scope.** `AdminActionController`
still has two `ResponseEntity.ok(true)` handlers — `triggerOrderReplenish:112` and
`triggerReleaseExpiredPickingOrdersFromUser:176` — but both drive jobs (`orderReleaseJob`,
`replenishJob`, `releaseExpiredPickingOrdersFromUserJob`) that are parts 2–4 of step 5 and still
expose `doCalculation(Boolean)`. Correctly out of scope for this PR; they must not be forgotten in
the remaining three.

**Test migration is faithful.** `CleanUpOldMessagesJobTest` / `CleanUpOldMessagesJobUnitTest` (the
known SBDEV-3102 duplicate pair) were migrated by entry-point substitution plus fixture wiring for
the new `TimezoneService` constructor arg; no `times(n)`, `never()` or assertion was weakened to fix a
compile error. `CleanUpOldMessagesJobMetricsUnitTest`'s one genuine assertion change —
`duration.count()` `isZero()` → `isEqualTo(1)` on the lock-busy path — is *correct and required*: the
whole-fire early return is gone, so the outer `finally` now always records. `WholeRunSuccessGaugeUnitTest`'s
removal of the now-unnecessary `tryLock(CLEAN_UP_MESSAGES)` stub under `STRICT_STUBS` is likewise
forced by the H-1 shape, not a weakening.

---

## Recommended pre-merge set

1. **M-1** — add the missing `doesNotTouchTheWholeRunGauges` equivalent to
   `CleanUpOldMessagesJobUnitTest.RunForCurrentTenantLocking`, asserting on the `SimpleMeterRegistry`
   (a mock `JobMetrics` is not available in that fixture). Mutation-check it with mutant H.
2. **M-2** — record a decision: either read the running landlord `maximumPoolSize` and put the number
   in the plan, or explicitly accept the risk for the remaining three step-5 jobs. Independently,
   reword `:181-183` so it does not assert "old-code replica" for a condition it cannot distinguish
   from pool exhaustion.
3. **L-1** — move `tenantSample = jobMetrics.startTenantTimer();` inside the following `try`
   (one line; round 2 assigned it to this PR by name).
4. **L-2** — one clause in the class javadoc so the `V2.2.20` citation reflects what `V2.2.20`
   actually says.
5. **L-3 … L-5** — same pass, all cosmetic or documentation.

Nothing here disputes the design. The D′ shape, the dual-lock decision, the per-tenant scoping and
the AC6 metric tradeoff are all correct as implemented, and the two gaps the authoring session found
by PIT before opening the PR are genuinely closed — I tried seven mutants against them and killed
every one.
