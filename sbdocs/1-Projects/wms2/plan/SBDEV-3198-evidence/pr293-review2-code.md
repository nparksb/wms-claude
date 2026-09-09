---
name: pr293-review2-code
description: Independent round-2 code review of wms2-api PR #293 (SBDEV-3198 step 5 part 2/4, ReleaseExpiredPickingOrdersFromUserJob → D′) at fix commit 02208807, verifying round 1's H-1/M-1/M-2/L-1..L-5 fixes by hand mutation
lane: code review round 2 (independent — this lane authored neither the PR nor the round-1 review)
reviewed: 2026-09-03
base: 64fb9223 (round-1 submission)
head: 02208807 (round-1 fix commit, current PR head)
worktree: /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-293-review2-code
---

# PR #293 — independent code review, round 2

## Verdict

**FIX BEFORE MERGE — the H-1 fix is behaviourally correct but its stated justification is false, and
the false part is load-bearing: it asserts a fact about `CleanUpOldMessagesJob` that the git history
contradicts, and that assertion is the exact reason nobody looked at the same defect now live on
`develop`.**

Round 1's substance was fixed. The activation gate really is restored, in the right place, with the
lock genuinely released on the not-activated return — I hoisted the guard above `tryLock()` and
`refusesWhenNotActivated` caught it. M-1's `anyFailure = true` is now killed by exactly one test, the
one the fix added; the deletion that survived the entire 6262-test suite in round 1 now fails in
0.07s. M-2's `@Version` rewrite is accurate: `AbstractBaseEntity:34-35` really declares
`@Version private Integer version`, `Pickingorder` really extends it, the job carries no
`@Transactional`, and `spring.jpa.open-in-view=false` (`application.properties:75`) — so the entities
really are detached and `save()` really is a version-checked merge. L-5's test really does exercise
the success path now: I mutated `return true` → `return false` on the success branch and the fixed
test failed at its new `assertThat(ran).isTrue()` (`:528`), a mutation the pre-fix version discarded
in silence. L-3's census recount comes out at exactly 154 → 163 over 39 classes, +9, matching the
corrected PR body; the 8-test-file count matches `git diff --name-only`. Full suite reproduces
**6264/0/0/67**, BUILD SUCCESS.

Two things are wrong, both introduced by the fix pass itself.

**N-1 (High).** The H-1 fix explains itself — in the class javadoc, in the inline comment, and in
three test comments — by asserting that `CleanUpOldMessagesJob`'s manual path *"was ALREADY
activation-flag-free before its own D′ conversion (a pre-existing quirk of that job specifically)."*
It was not. At `e83d9550` (the commit immediately before that job's D′ conversion),
`CleanUpOldMessagesJob.doCalculation(false)` put the caller's tenant through the same shared loop as
the fleet, activation gate included (`:93-106`) — structurally identical to this job. Its D′
conversion dropped the gate, and the merged code on `develop` (`c360b380:305-341`) goes `tryLock` →
`archiveOldMessages()` with no activation check at all. So H-1 is not a one-off this PR avoided; it
is a defect **already shipped** in PR #291, and this PR's fix note is precisely the sentence that
tells the next reader not to go look. The same shared-loop shape is still live in `OrderReleaseJob`
(`:114-123`) and `ReplenishOrderJob` (`:147-156`), the two jobs steps 5 parts 3-4 will convert
against this javadoc.

**N-2 (Medium).** `refusesWhenNotActivated`, the regression test the fix added for H-1, does not kill
the H-1 mutant. I deleted the restored activation block outright and ran
`ReleaseExpiredPickingOrdersFromUserJobTest`: **22 run, 0 failures, BUILD SUCCESS**, `refusesWhenNotActivated`
among the green. It passes for the wrong reason — with the guard gone, control reaches
`releaseExpiredPickingOrders()`, the unstubbed `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE_KEY` returns
`null`, `Integer.parseInt(null)` throws, the `catch` returns `false`, and all three assertions
(`ran` false, `verifyNoInteractions(pickingorderRepository)`, `unlock` called) still hold. This is the
identical failure mode round 1 filed as L-5, reproduced inside L-5's own fix pass. The only thing that
kills the mutant anywhere in the suite is a Mockito `UnnecessaryStubbing` error in a *different* class
— and the natural remedy for that error message is to delete the stub, which is exactly what the
pre-fix author did (the round-1-era comment read *"calling `activated()` here would stub the two
ACTIVATED_KEY sysprops unnecessarily"*).

Counts: **1 High**, **1 Medium**, **2 Low** — all new. All eight round-1 findings are resolved in
substance.

## Evidence collected

| Instrument | Result |
|---|---|
| `mvn -o clean test` (full suite, HEAD `02208807`) | **6264 run, 0 failures, 0 errors, 67 skipped** — BUILD SUCCESS. Matches the PR's claim exactly |
| Hand mutant **1** — delete the restored activation `if` from `runForCurrentTenant()` (`:294-299`), scoped to `ReleaseExpiredPickingOrdersFromUserJobTest` | **SURVIVED** — 22 run, 0 failures, BUILD SUCCESS. `refusesWhenNotActivated` green. See N-2 |
| Hand mutant **1**, widened to the 5 touched test classes | **KILLED, but only by `UnnecessaryStubbing`** — 71 run, 0 failures, **2 errors**: `AdminTriggerTenantScopeUnitTest$ReleaseExpiredPicking.{adminTrigger_runsOnlyTheCallersTenant, adminTrigger_leavesTheCallersContextIntact}`. No assertion anywhere observed the missing gate |
| Hand mutant **2** — drop only the `NEW_CRON_JOB_ACTIVATED_KEY` clause from the manual path's condition | **KILLED, again only by `UnnecessaryStubbing`** — 47 run, 0 failures, 2 errors, same two tests. The global cron kill switch is pinned by no assertion on this path |
| Hand mutant **3** — hoist the activation guard ABOVE `tryLock()` | **KILLED** — 38 run, **1 failure**: `refusesWhenNotActivated:581` (`verify(advisoryLockService).unlock(…)`). Placement and lock-release ARE pinned; existence is not |
| Hand mutant **4** — delete `anyFailure = true` from the malformed-row branch (`:154`) | **KILLED** — 22 run, **1 failure**: `RunForEdgeCases.malformedRowCostsOnlyItselfButWithholdsFleetGauge:346` (the fleet-gauge assertion). Round 1's survivor is closed. **M-1 resolved** |
| Hand mutant **5** — `runForCurrentTenant()` success path `return true` → `return false` | **KILLED** — `AdminTriggerTenantScopeUnitTest$ReleaseExpiredPicking.adminTrigger_leavesTheCallersContextIntact:528` and `adminTrigger_runsOnlyTheCallersTenant:483`. The L-5 test genuinely covers the success path now. **L-5 resolved** |
| `git checkout --` + `git status --porcelain` after every mutant | Clean; nothing left on disk; HEAD still `02208807` |
| `AbstractBaseEntity.java:34-35` | `@Version private Integer version;` under `@MappedSuperclass`; `Pickingorder.java:10` extends it. **M-2's premise holds** |
| `grep -n "Transactional" ReleaseExpiredPickingOrdersFromUserJob.java` | **No match** (exit 1) |
| `application.properties:75` | `spring.jpa.open-in-view=false` — entities genuinely detached on both the scheduled AND the manual (HTTP) path, so `save()` is a version-checked merge in both. **M-2's mechanism holds** |
| `git show e83d9550:…/CleanUpOldMessagesJob.java` (the commit before its D′ conversion) | `:89` `tenantProfiles = List.of(callerTenant)` → `:93` shared loop → `:101-106` **activation gate + `tenantSkippedNotActivated` + `continue`**. The manual path WAS activation-gated. See N-1 |
| `git show c360b380:…/CleanUpOldMessagesJob.java:305-341` (merged develop tip) | `runForCurrentTenant()`: context → landlord row → int4 → `tryLock` → `archiveOldMessages()`. **Zero activation check.** The H-1 defect is live on `develop` |
| `grep -n … OrderReleaseJob.java` / `ReplenishOrderJob.java` | Both still carry the pre-D′ shared-loop shape with the activation gate on the manual path (`:110-123` / `:143-156`) — the same trap awaits parts 3-4 |
| `NeverMatcherNullBlindnessArchTest` census, recomputed from both sides of the diff by script | OLD 39 entries / sum **154** → NEW 39 entries / sum **163**, delta **+9**; only `AdminTriggerTenantScopeUnitTest` 2→4 and `ReleaseExpiredPickingOrdersFromUserJobTest` 2→9 changed. **PR body's corrected figure is right** |
| `git diff c360b380..02208807 --name-only \| grep -c "^src/test/"` | **8**. PR body's corrected count is right |
| `grep -c "jobMetrics\." StaleClubBatchCleanupJob.java` | **0** — L-1's fix comment claim ("zero `JobMetrics` calls of any kind, confirmed by grep") is true |
| `grep -rn "skippedLockBusy()" src/main` | `OrderReleaseJob:87`, `ReplenishOrderJob:120`, `StockSummaryExportJob:276`, `CleanUpOldMessagesJob:213` — all one-key paths, none in this job. L-1's corrected reasoning holds |

---

## N-1 (High, new) — the H-1 fix's justification is factually false, and the false part is what stops anyone finding the same defect already merged to `develop`

The behaviour fix is right. The explanation attached to it is not, and it is repeated in five places:

- `ReleaseExpiredPickingOrdersFromUserJob.java:233-241` (class-level javadoc on `runForCurrentTenant()`)
- `ReleaseExpiredPickingOrdersFromUserJob.java:287-293` (inline comment above the restored guard)
- `ReleaseExpiredPickingOrdersFromUserJobTest.java:564` (`@DisplayName`: *"unlike `CleanUpOldMessagesJob`'s manual trigger"*)
- `AdminTriggerTenantScopeUnitTest.java:472-476`
- the PR description's H-1 paragraph

All five rest on this sentence:

> *"it was templated on `CleanUpOldMessagesJob.runForCurrentTenant()`, whose manual path was ALREADY
> activation-flag-free before its own D′ conversion — a pre-existing quirk of that specific job, not
> a D′ decision."*

**It was not a pre-existing quirk.** `git show e83d9550:src/main/java/net/aim_ai/wms/schedulejob/CleanUpOldMessagesJob.java`
— the commit immediately preceding `55ec08e1` *"SBDEV-3198 step 5 (1/4): convert CleanUpOldMessagesJob to D'"* — reads:

```java
 89            tenantProfiles = List.of(callerTenant);      // manual path: one tenant
 90        }
 92        boolean anyFailure = false;
 93        for (TenantProfile tenantProfile : tenantProfiles) {
101            if (!Boolean.parseBoolean(syspropService.getSysvalue(SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY))
102                || !Boolean.parseBoolean(syspropService.getSysvalue(SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY))) {
104                jobMetrics.tenantSkippedNotActivated(tenantName);
105                continue;
106            }
108            archiveOldMessages();
```

That is the *same* shared-loop shape this PR correctly identifies in its own pre-D′ job. The manual
path was activation-gated in both. `CleanUpOldMessagesJob`'s D′ conversion is what dropped it, and
the merged code on `develop` (`c360b380:327-334`) still has no gate:

```java
327        if (!advisoryLockService.tryLock(JobLockId.CLEAN_UP_MESSAGES, tenantId)) { … return false; }
332        try {
333            archiveOldMessages();
334            return true;
```

Three consequences, in order of cost:

1. **A live defect on `develop`, shipped by PR #291.** `GET /v3/adminAction/triggerArchiveMessages`
   against a tenant with `clean_up_old_messages_activated = false` now archives that tenant's
   messages. Round 1 rated the identical situation on this job High. It is out of this PR's diff, so
   it is not this PR's to fix — but it is this PR's to stop asserting is fine.
2. **The javadoc licenses the next two conversions to repeat it.** The class javadoc explicitly
   designates this file as the template for `OrderReleaseJob` and `ReplenishOrderJob`, and both still
   carry the gated shared loop (`OrderReleaseJob:114-123`, `ReplenishOrderJob:147-156`). An engineer
   converting those, reading *"the sibling was activation-free as a pre-existing quirk"*, has been
   handed a reason not to check — which is exactly how this defect propagated the first time.
3. **It is the same class of defect round 1 filed H-1 for**: a javadoc asserting something the code
   denies. Here the denial is one repo away rather than six lines away, which is why it survived a
   fix pass whose whole subject was this sentence.

**Fix:** replace the "pre-existing quirk" claim in all five places with what the history actually
shows — the sibling's D′ conversion dropped a gate it used to have, this job did not repeat that —
and raise the `CleanUpOldMessagesJob` gap with Nam as a proposed finding against the already-merged
PR #291 (per the ticket policy: `on dev` or later ⇒ propose a new ticket, do not extend the shipped
one).

---

## N-2 (Medium, new) — `refusesWhenNotActivated` does not kill the mutant it exists to kill; the only thing that does is an `UnnecessaryStubbing` error in another class

`ReleaseExpiredPickingOrdersFromUserJobTest.java:563-582`:

```java
void refusesWhenNotActivated() {
    …tryLock(RELEASE_EXPIRED_PICKING, 5L) → true
    …getSysvalue(NEW_CRON_JOB_ACTIVATED_KEY)        → "true"
    …getSysvalue(PICK_TIME_OUT_SYSTEM_ACTIVATED_KEY) → "false"

    boolean ran = job.runForCurrentTenant();

    assertThat(ran).isFalse();
    verifyNoInteractions(pickingorderRepository);
    verify(advisoryLockService).unlock(RELEASE_EXPIRED_PICKING, 5L);
}
```

The class is `@MockitoSettings(strictness = Strictness.LENIENT)` (`:46`) and
`PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE_KEY` is not stubbed. **Delete the guard entirely and every
assertion still passes**, because the fall-through path is:

`releaseExpiredPickingOrders()` → `getSysvalue(TIME_OUT_VALUE)` → `null` → `Integer.parseInt(null)`
throws `NumberFormatException` → caught at `:302` → `return false` → `finally` unlocks. `ran` is
false; `pickingorderRepository` was never reached, so `verifyNoInteractions` holds; `unlock` was
called. Measured:

```
mvn -o test -Dtest=ReleaseExpiredPickingOrdersFromUserJobTest
[INFO] Tests run: 22, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

Round 1's L-5 was *"a test that silently drifted off testing what it claimed, because
`Integer.parseInt(null)` threw first."* This is that, in the test written to close round 1's H-1.

Widening the run does produce a red, but not from an assertion:

```
[ERROR] AdminTriggerTenantScopeUnitTest$ReleaseExpiredPicking.adminTrigger_leavesTheCallersContextIntact » UnnecessaryStubbing
[ERROR] AdminTriggerTenantScopeUnitTest$ReleaseExpiredPicking.adminTrigger_runsOnlyTheCallersTenant   » UnnecessaryStubbing
```

That is `STRICT_STUBS` noticing `activated()`'s now-unused sysprop stubs. It is a real kill today,
but it is the weakest possible instrument for a guard on live picking-state writes, for a specific
reason: **the documented remedy for `UnnecessaryStubbing` is to remove the stub**, and removing the
stub is literally what produced round 1's H-1 in the first place — commit `64fb9223` deleted
`activated()` from that test with the comment *"calling `activated()` here would stub the two
ACTIVATED_KEY sysprops unnecessarily."* A future engineer hitting these two errors will do the same
thing again, and the guard will be pinned by nothing at all.

The same measurement holds for the global kill switch alone: dropping just the
`NEW_CRON_JOB_ACTIVATED_KEY` clause produces 0 failures and the same 2 `UnnecessaryStubbing` errors.

What the test *does* pin is placement: hoisting the guard above `tryLock()` fails it at `:581`
(`verify(advisoryLockService).unlock(…)`), which is worth keeping.

**Fix (two lines):** stub `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE_KEY` → `"60"` and
`getPickingOrdersToReleaseExpiredPickingOrders(...)` → a **non-empty** list in
`refusesWhenNotActivated`, so that removing the guard makes the release genuinely succeed and
`assertThat(ran).isFalse()` / `verifyNoInteractions(pickingorderRepository)` both go red on their own
merits. A `verify(syspropService, never()).getSysvalue(PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE_KEY)` is
the cheaper alternative and pins the same thing. Add the mirror case with
`NEW_CRON_JOB_ACTIVATED_KEY = "false"` so both halves of the condition are covered by an assertion
rather than by stub bookkeeping.

---

## N-3 (Low, new) — the restored not-activated path is metric-silent, where its `runFor()` twin emits `tenantSkippedNotActivated`, and the class javadoc's metrics paragraph disclaims only the whole-run gauges

`runFor():195-200` skips a deactivated tenant with `jobMetrics.tenantSkippedNotActivated(tenantName)`.
`runForCurrentTenant():294-299` — the path H-1 restored — emits nothing. Pre-D′
(`c360b380:110-116`) the manual path emitted it too, because it shared the loop.

The class javadoc (`:80-86`) says only that *"the whole-run gauges (`markLastRun`, `recordDuration`,
`markLastSuccess`) … `runForCurrentTenant()` deliberately does NOT touch them."* True but narrower
than the code: the method touches **no** `JobMetrics` at all — not `tenantSuccess`, not
`tenantFailure`, not `tenantSkippedNotActivated`. That decision is written down only in two test
comments (`AdminTriggerTenantScopeUnitTest:273-278`, `:474-476`), citing `StockSummaryExportJob`'s
step-4 M-2 precedent — an accepted pattern, not a defect. But H-1's fix adds a *new* silent outcome
to it: an admin clicks "run now" on a deactivated tenant, gets `false`, and nothing in metrics or at
INFO records that it happened. Combined with L-1's finding that lock-busy is also fully
metric-invisible for this job, the manual trigger is now unobservable in three of its five outcomes.

One sentence in the class javadoc's metrics paragraph — "no per-tenant counters either, by the same
reasoning" — makes the code and the doc agree, which is all this needs.

---

## N-4 (Low, new) — two wording defects in the round-1 fix text

Both in prose the next two conversions are meant to clone.

1. `ReleaseExpiredPickingOrdersFromUserJob.java:48-49`: *"`@Version` is also what prevents an actual
   lost-update — **a lock-busy predicate** alone would not."* There is no "lock-busy predicate"; the
   thing being contrasted is the `lockedtooperator = true` row predicate in the candidate query. The
   phrase collides with the advisory-lock "lock busy" concept used everywhere else in this file and
   in `JobMetrics.skippedLockBusy()`. Say `lockedtooperator = true` predicate.
2. `AdminTriggerTenantScopeUnitTest.java:516-518`: *"the unstubbed `TIME_OUT_VALUE_KEY` sysprop
   returned null under **STRICT_STUBS's lenient-by-default Mockito behaviour**."* Self-contradictory
   — `STRICT_STUBS` is the opposite of lenient, and it is not what makes an unstubbed method return
   null (every Mockito mock does that at any strictness; strictness governs *unused* stubs). The
   comment also attributes the pre-fix miss to H-1's absent activation stubs, when the actual cause
   was the missing `TIME_OUT_VALUE_KEY` stub — which is why the identical mechanism is still live in
   `refusesWhenNotActivated` (N-2). Worth correcting precisely because the mechanism repeated.

---

## Round-1 findings — resolved

### H-1 (High) — **RESOLVED in behaviour; see N-1 for its justification and N-2 for its test**

The gate is back at `:294-299`, inside the `try` whose `finally` unlocks (`:305-307`), after
`tryLock` and before `releaseExpiredPickingOrders()` — the same relative position as `runFor()`'s
(`:195-201`, inside its own lock-releasing `try`). Both flags, same order, same `WmsConstants` keys as
the pre-D′ loop (`c360b380:110-111`). The `@return` javadoc now lists "not activated" among the
`false` cases, and the false parenthetical round 1 quoted is gone.

**The lock is released correctly when activation is false** — hand-verified two ways: the guard's
`return false` passes through the `finally` at `:305-307`, and hoisting the guard above `tryLock`
(where no lock is held) makes `refusesWhenNotActivated:581`'s `verify(…).unlock(…)` fail. So the fix
did not go too far in the direction round 1 warned about.

Did it go far enough? Behaviourally yes; evidentially no (N-2); documentarily no (N-1, N-3).

### M-1 (Medium) — **RESOLVED, and pinned by exactly the right assertion**

`malformedRowCostsOnlyItselfButWithholdsFleetGauge` (`ReleaseExpiredPickingOrdersFromUserJobTest:320-350`)
builds a `TenantDbConfiguration` with `setTenant(null)`, pairs it with a valid sibling, and asserts
(a) the sibling still ran, (b) `last_success_epoch_seconds` is **zero**, (c) no lock was attempted for
the malformed row. Deleting `anyFailure = true` — the mutation that survived all 6262 tests in round
1 — now fails assertion (b) at `:346` in 0.07s. The deliberate divergence from
`CleanUpOldMessagesJob`/`StaleClubBatchCleanupJob`'s `anyReadFailure`-only shape is explained at the
branch (`:145-151`). The branch is also no longer `NO_COVERAGE`, which repairs the PR's own claim.

### M-2 (Medium) — **RESOLVED, and the rewrite is accurate, not an overcorrection**

Every load-bearing element verified independently:

- `AbstractBaseEntity.java:34-35` — `@Version private Integer version;`, under `@MappedSuperclass`.
- `Pickingorder.java:10` — `public class Pickingorder extends AbstractBaseEntity`.
- `grep -n "Transactional"` on the job — **no match**, so no ambient transaction keeps a session open.
- `application.properties:75` — `spring.jpa.open-in-view=false`. This matters more than round 1 said:
  with OSIV **on**, the manual (HTTP-request) path would keep the entities managed, and the "detached
  ⇒ merge" half of the argument would hold only for the scheduled path. It is off, so the javadoc is
  correct for both entry points.
- The consequence chain the rewrite states — optimistic-lock failure propagates out of
  `releaseExpiredPickingOrders()` → `runFor()`'s per-tenant `catch` (`:210-213`) → `tenantFailure` +
  `anyFailure = true` → `markLastSuccess()` withheld at `:219` — matches the code line for line.

The rewrite adds the lost-update scenario and an explicit "do not carry this forward without
confirming `@Version`" instruction to steps 5 parts 3-4. That is the right generalisation. Only the
`lock-busy predicate` phrasing is off (N-4).

### L-1 (Low) — **RESOLVED**

The `StaleClubBatchCleanupJob` citation is gone. `grep -c "jobMetrics\." StaleClubBatchCleanupJob.java`
= **0**, so the comment's stated reason for dropping it is true. `grep -rn "skippedLockBusy()" src/main`
confirms all four call sites sit on one-key paths (`OrderReleaseJob:87`, `ReplenishOrderJob:120`,
`StockSummaryExportJob:276`, `CleanUpOldMessagesJob:213`), so the replacement explanation — no
one-key layer for the counter to sit on — is correct. The comment now says plainly that a stuck
per-tenant lock is fully metric-invisible for this job, which is what round 1 asked for.

### L-2 (Low) — **RESOLVED**

`:168-176` explains the int4 branch's silence on `anyFailure` and states explicitly that
`StaleClubBatchCleanupJob`'s `anyMember`-based rationale does not transfer, since this job has no
`anyMember` concept. Real comment, at the right line, saying the right thing.

### L-3 (Low) — **RESOLVED**

Recomputed independently from both sides of the diff: OLD 39 entries / sum **154**, NEW 39 entries /
sum **163**, delta **+9**, changed rows `AdminTriggerTenantScopeUnitTest` 2→4 and
`ReleaseExpiredPickingOrdersFromUserJobTest` 2→9. The PR body now says 154→163 / +9. The arch test
itself passes in the full suite, which is the second instrument on the same claim. The related
"9 test files" → **8** correction also checks out: `git diff c360b380..02208807 --name-only | grep -c "^src/test/"` = 8.

### L-4 (Low) — **RESOLVED**

`AdminActionController.java:162-174` no longer names `doCalculation(false)` as the current contract;
it says "the manual trigger", and adds a note recording that the block is shared preamble across six
handlers, that two of the four jobs have already moved to `runForCurrentTenant()`, and that this
sentence — not just the per-handler notes — must be updated when parts 3-4 land. That is a stronger
fix than round 1 asked for.

### L-5 (Low) — **RESOLVED, and hand-verified to now cover what it claims**

`adminTrigger_leavesTheCallersContextIntact` gains `activated()` (which in this nested class stubs
both flags, the timeout value, **and** the repository query — `:448-454`) and
`assertThat(ran).isTrue()`. Hand-verified rather than read: mutating the success path's `return true`
→ `return false` fails it at `:528`, and also fails `adminTrigger_runsOnlyTheCallersTenant:483`. Before
the fix, that test discarded the return value entirely, so the mutation would have passed unnoticed.
The comment explaining why is imprecise (N-4) but the test is right.

The sibling change to `adminTrigger_runsOnlyTheCallersTenant` — swapping two inline stubs for
`activated()` — is equivalent-plus-activation, since `activated()` is a superset of what it replaced.
It still asserts `ran == true`, the direct repository verification, `never().findByActiveTrue()`, and
the zero fleet gauge.

---

## Verified — what I tried to break and could not

- **Full suite at the fix commit.** `6264/0/0/67`, BUILD SUCCESS, matching the PR body exactly and
  +12 over the 6252 post-#291 baseline as claimed.
- **The three round-1-modified `RunForCurrentTenantLocking` tests still test their names.**
  `returnsFalseAndReleasesLockOnException` (activation stubs added, then TIME_OUT throws) still
  reaches the `catch`; `returnsTrueAndReleasesLockOnSuccess` and `doesNotTouchTheWholeRunGauges` both
  still assert `ran == true` plus their original claims, and both were killed by mutant 5, so neither
  drifted onto a refusal path when the activation stubs were added. No repeat of L-5 in this class.
- **Both `AdminTriggerTenantScopeUnitTest$ReleaseExpiredPicking` touched tests.** Killed by mutant 5
  at their own assertion lines (`:483`, `:528`) — they exercise the success path, as their names say.
  The two untouched tests in that nested class (`adminTrigger_withNoTenantContext_doesNothing`,
  `cronRun_stillLoopsEveryActiveTenant`) are unaffected by the activation change.
- **Lock lifecycle on the manual path, re-derived post-fix.** Five outcomes, lock released in exactly
  the two-plus-two cases it was taken: three pre-lock refusals return before `tryLock`; lock-busy
  returns without unlocking; not-activated, success and exception all exit through the shared
  `finally`. Mutant 3 (hoisting the guard) is the case round 1 could not have tested, and it is caught.
- **`runFor()` is untouched by the fix pass** apart from two comments — `git diff 64fb9223..02208807`
  shows no executable change inside it, so round 1's four killed lock-lifecycle mutants still stand.
- **The `@Disabled` duplicate-pair partner** (`ReleaseExpiredPickingOrdersFromUserJobUnitTest`) is
  still compile-fixed only; the fix commit does not touch it.
- **No new production caller.** The fix commit's `src/main` diff is confined to
  `ReleaseExpiredPickingOrdersFromUserJob` (one executable hunk, the restored guard) and an
  `AdminActionController` comment block.

---

## Recommended pre-merge set

1. **N-1** — correct the "pre-existing quirk" claim in all five places (class javadoc `:233-241`,
   inline comment `:287-293`, `@DisplayName` `:564`, `AdminTriggerTenantScopeUnitTest:472-476`, PR
   body). Separately, raise `CleanUpOldMessagesJob.runForCurrentTenant()`'s missing activation gate
   with Nam as a **proposed** finding against merged PR #291 — do not fold it into this PR, and note
   that `OrderReleaseJob`/`ReplenishOrderJob` must not repeat it in parts 3-4.
2. **N-2** — make `refusesWhenNotActivated` kill the deletion mutant on its own assertions (stub
   `TIME_OUT_VALUE_KEY` + a non-empty order list, or add
   `verify(syspropService, never()).getSysvalue(TIME_OUT_VALUE_KEY)`), and add the mirror case for
   `NEW_CRON_JOB_ACTIVATED_KEY = "false"`.
3. **N-3** — one sentence in the class javadoc's metrics paragraph covering the per-tenant counters,
   not just the whole-run gauges.
4. **N-4** — `lock-busy predicate` → `lockedtooperator = true` predicate; fix the
   `STRICT_STUBS`/lenient sentence and its misattributed cause.
