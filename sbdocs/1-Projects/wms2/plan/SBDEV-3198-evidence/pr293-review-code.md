---
name: pr293-review-code
description: Independent code review of wms2-api PR #293 (SBDEV-3198 step 5 part 2/4, ReleaseExpiredPickingOrdersFromUserJob → D′) at commit 64fb9223
lane: code review (independent — this lane did not author the PR)
reviewed: 2026-09-03
base: c360b380 (develop tip, the PR #291 merge commit)
head: 64fb9223
worktree: /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-293-review-code
---

# PR #293 — independent code review

## Verdict

**FIX BEFORE MERGE — one behaviour change that the code's own javadoc denies, plus one unpinned new
branch.**

The mechanical parts of this conversion are sound and I could not break them. Every one of the four
lock-lifecycle mutants I hand-planted was killed, precisely and by the right test: deleting
`runFor()`'s per-tenant `unlock` kills exactly the two `PerTenantLockRelease` tests that name it;
deleting the int4-overflow `continue` kills exactly `skipsInt4OverflowingTenantWithoutLocking`;
dropping `runForCurrentTenant()`'s lock-busy `return false` kills `refusesWhenLockBusy`; and adding
a whole-run gauge write into `runForCurrentTenant()` kills `doesNotTouchTheWholeRunGauges` **and**
`adminTrigger_runsOnlyTheCallersTenant`. That last pair is the M-1 gap PR #291's review had to
find — this PR closed it up front, as it claims. The full suite reproduces **6262/0/0/67** exactly.
The `NeverMatcher` census is arithmetically correct (I recounted all seven new sites by hand and
summed both inventories). Claim 4 (one hardcoded fleet-wide cron, no schedule sysprop) and claim 5
(`skippedLockBusy()` genuinely never called) both hold.

What it missed is on the *manual* path, and it is not a metrics gap this time. **The old
`doCalculation(false)` checked the two activation sysprops before releasing anything; the new
`runForCurrentTenant()` does not check them at all.** An admin clicking "run now" on a tenant that
has deliberately set `pick_time_out_system_activated = false` now performs the release anyway. The
tests know this — `adminTrigger_runsOnlyTheCallersTenant` deletes its `activated()` call with a
comment saying so — but the method's own javadoc asserts the opposite in a parenthetical
(*"activation IS still checked once locked, matching `runFor()`"*), and the PR description does not
mention the change at all. Whichever way Nam decides, that sentence cannot ship as written (§H-1).

Second: `runFor()`'s malformed-row branch sets `anyFailure = true`, which withholds
`markLastSuccess()`. That is **new** behaviour — `CleanUpOldMessagesJob` sets only `anyReadFailure`
there, which does not withhold the gauge — and it is pinned by nothing. I deleted the assignment and
ran the **entire** suite: `6262 run, 0 failures, 0 errors, 67 skipped`, BUILD SUCCESS. No test for
this job constructs a config with a null tenant or blank warehouse, so the whole branch is unreached,
which also contradicts the PR's "zero `NO_COVERAGE` remaining" claim (§M-1). `StaleClubBatchCleanupJob`
has the precedent test (`malformedRowCostsOnlyItself`) and it was not cloned.

Third, on the review question I was asked to attack hardest — the no-dual-lock idempotency argument.
**The conclusion is right; the stated reason is not the reason.** `Pickingorder` extends
`AbstractBaseEntity`, which carries `@Version`. A concurrent double-run does not quietly "converge to
the same end state": the loser's `save()` (a detached-entity `merge`) raises an optimistic-lock
failure that aborts that tenant's remaining rows and books a `tenant_failure`. `@Version` is in fact
what makes the double-run *safe* — it is also what blocks the lost-update where run B re-releases an
order a live operator claimed between run A's commit and run B's save. Since this javadoc is
explicitly designated as the template for `OrderReleaseJob` and `ReplenishOrderJob`, and neither of
those is a single-column flip, propagating "it's a plain UPDATE so it converges" is the part worth
correcting (§M-2).

Counts: **1 High**, **2 Medium**, **5 Low**.

## Evidence collected

| Instrument | Result |
|---|---|
| `mvn -o clean test` (full suite, HEAD `64fb9223`) | **6262 run, 0 failures, 0 errors, 67 skipped** — BUILD SUCCESS, 3m45s. Matches the PR's claim exactly |
| Hand mutant **A** — delete `unlock(RELEASE_EXPIRED_PICKING, tenantId)` from `runFor()`'s per-tenant `finally` (`:178`) | **KILLED** — 20 run, **2 failures** (`releasesLockOnException:436`, `releasesLockOnSuccess:451`); `skipsInt4Overflow…` correctly stayed green |
| Hand mutant **B** — delete the `continue` from `runFor()`'s int4-overflow `catch` (`:150`) | **KILLED** — 20 run, **1 failure** (`skipsInt4OverflowingTenantWithoutLocking:467`) |
| Hand mutant **C** — delete `runForCurrentTenant()`'s lock-busy `return false` (`:244`), letting the guard fall through | **KILLED** — 20 run, **1 failure** (`refusesWhenLockBusy:527`, the `never().unlock(…)` assertion) |
| Hand mutant **D** — add `jobMetrics.markLastSuccess()` into `runForCurrentTenant()`'s success path | **KILLED** — 36 run, **2 failures** (`doesNotTouchTheWholeRunGauges:586` **and** `AdminTriggerTenantScopeUnitTest$ReleaseExpiredPicking.adminTrigger_runsOnlyTheCallersTenant:493`) |
| Hand mutant **E** — delete `anyFailure = true` from `runFor()`'s malformed-row branch (`:133`) | **SURVIVED the FULL suite** — 6262/0/0/67, BUILD SUCCESS, exit 0. See M-1 |
| `git checkout --` + `git status --porcelain` after every mutant | Clean; no mutant left on disk |
| `PickingorderRepository:91-100` — the candidate query | `WHERE po.lockedtooperator = true AND po.pickinginprogress = false AND po.modified < :timeOut AND po.state < :state AND s.sectionpickingtype = :pickingType`. The `lockedtooperator = true` premise **holds** |
| `AbstractBaseEntity:32-33` | `@LastModifiedDate private LocalDateTime modified;` **and `@Version private Integer version;`** — `Pickingorder` is optimistically locked. Not mentioned anywhere in the idempotency argument. See M-2 |
| `SchedulingConfiguration:942-957` | `String cronjob = "40 * * * * *"` hardcoded; the only `getSysvalue` is `CRON_JOB_SHOW_LOG_KEY` (a global log flag, not a schedule). **Claim 4 confirmed** — no per-tenant schedule read, no group derivation |
| `grep -rn "skippedLockBusy()" src/main` | 4 call sites: `CleanUpOldMessagesJob:213`, `ReplenishOrderJob:120`, `StockSummaryExportJob:276`, `OrderReleaseJob:87`. **Zero in the new job.** Claim 5 confirmed |
| `grep -n "jobMetrics\|JobMetrics" StaleClubBatchCleanupJob.java` | One hit — a javadoc line saying it *"has no `JobMetrics` at all"*. The cited precedent has no metrics to omit. See L-1 |
| `grep -rn "releaseExpiredPickingOrdersFromUserJob\." src/main` | Exactly **2** production callers — `SchedulingConfiguration:950` (`runFor()`) and `AdminActionController:180` (`runForCurrentTenant()`). No caller missed, no `doCalculation` left behind for this job |
| `never()`-with-primitive-matcher census, recounted by hand from `grep -n "never()"` | `ReleaseExpiredPickingOrdersFromUserJobTest` = 2×`anyInt()` (`:199`, `:218`) + 1×`anyLong()` (`:467`) + 3 sites × 2×`anyLong()` (`:497`, `:511`, `:527`) = **9** ✔; `AdminTriggerTenantScopeUnitTest` = 2 sites × 2 (`:310`, `:513`) = **4** ✔ |
| Inventory sums, computed from the source both sides | old **154** / 39 classes → new **163** / 39 classes. Code is right; the PR body's "156→163" is not (L-3) |
| `grep -rn "setTenant(null)\|setWarehouse(\"\")" ` across all four test classes touching this job | **Zero** — the malformed-row branch is unreached by any test. `StaleClubBatchCleanupJobUnitTest:412` has the precedent test for its own job |
| `awk 'NR>=219 && NR<=256'` over `runForCurrentTenant()` grepping for `ACTIVATED` | **No match.** The only sysprop the manual path reads is `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE_KEY`, inside `releaseExpiredPickingOrders()`. See H-1 |

---

## H-1 (High) — the manual admin trigger silently loses its activation gate, and the javadoc asserts that it did not

`ReleaseExpiredPickingOrdersFromUserJob.java:196-201`:

> *"Behaviour preserved from `doCalculation(false)`'s AC13(b) shape: no activation-flag skip on
> refusal paths below the lock (**activation IS still checked once locked, matching `runFor()`**),
> current `TenantContext` only"*

The parenthetical is false. `runForCurrentTenant()` (`:219-255`) goes from `tryLock` straight to
`releaseExpiredPickingOrders()`. Grepping lines 219-256 for `ACTIVATED` returns nothing.

**This is a behaviour change, not a restatement.** The old `doCalculation(Boolean)` put the manual
caller through the *same* loop as the scheduled fleet — `tenantProfiles = List.of(callerTenant)` —
and that loop contained:

```java
if (!Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY))
    || !Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_PICK_TIME_OUT_SYSTEM_ACTIVATED_KEY))) {
    ...
    jobMetrics.tenantSkippedNotActivated(tenantName);
    continue;
}
releaseExpiredPickingOrders();
```

So before this PR, `GET /v3/adminAction/triggerReleaseExpiredPickingOrdersFromUser` against a tenant
with `pick_time_out_system_activated = false` did nothing and incremented `skipped_not_activated`.
After it, that same click clears `operatorId` and `lockedtooperator` on every picking order matching
the timeout predicate. `NEW_CRON_JOB_ACTIVATED_KEY` is the *global* cron kill switch, so this also
applies to an environment deliberately quiesced at that flag.

The scheduled path is unaffected — `runFor():165-171` still checks both flags.

Two things make this worth High rather than Medium despite needing an admin click and
`WEB_UI_VIEW_IMPORT_DATA`:

1. It is a **write to live picking state** for a tenant that explicitly turned the feature off, and
   the endpoint's HTTP response cannot distinguish it (it returned `true` before, and returns `true`
   now).
2. Nothing in the change discloses it. The PR description lists the manual path's changes as
   *tenant-scoping* and *lock widening* only. The javadoc denies it outright. A future engineer
   auditing whether the activation gate is honoured will read that parenthetical and stop.

**Mitigation that is not a fix:** a tenant with the feature disabled may also have no usable
`pick_time_out_system_time_out_value`, in which case `Integer.parseInt(null)` throws, is caught, and
the call returns `false` harmlessly. That is a coincidence of two independent sysprops, not a guard.

**Note this may be intended.** `CleanUpOldMessagesJob.runForCurrentTenant()` (merged, step 5 part 1)
states plainly *"no activation-flag check"* and its code matches — so "a manual trigger runs
regardless of the schedule gate" is a live precedent. If that is the decision here too, the fix is:
correct the javadoc parenthetical, disclose the change in the PR description, and add a test pinning
that the manual path runs with `PICK_TIME_OUT_SYSTEM_ACTIVATED = false`. If it is not the decision,
restore the gate. Either way the current sentence cannot ship.

---

## M-1 (Medium) — `runFor()`'s malformed-row `anyFailure = true` is new, diverges from the sibling it cites, and survives the entire 6262-test suite

`ReleaseExpiredPickingOrdersFromUserJob.java:127-135`:

```java
if (config.getTenant() == null || ... || config.getWarehouse().isBlank()) {
    LOG.error("{}: malformed tenant_db_configuration row (id={}) — skipped, not "
        + "aborting the rest of this occurrence", JOB_NAME, config.getId());
    anyFailure = true;          // ← this line
    continue;
}
```

The javadoc for `runFor()` says this guard is *"mirroring the same guard on every already-converted
job"*. The **guard** mirrors them; the **`anyFailure = true`** does not. `CleanUpOldMessagesJob:170`
and `StaleClubBatchCleanupJob:151` both set `anyReadFailure` at that point — a flag that feeds only a
log distinction and does **not** gate `markLastSuccess()`. This job routes it into `anyFailure`,
which does (`:189`). So a malformed landlord row now withholds the fleet freshness gauge for this
job and for no other. That is arguably the better choice, but it is undocumented and untested.

**Measured:** I deleted the assignment and ran `mvn -o test` over the whole tree:

```
[WARNING] Tests run: 6262, Failures: 0, Errors: 0, Skipped: 67
EXIT=0
```

Identical to the unmutated baseline. Not one assertion anywhere observes it.

The cause is that the whole branch is unreachable in test: `grep -rn "setTenant(null)\|setWarehouse(\"\")\|setWarehouse(null)"` across `ReleaseExpiredPickingOrdersFromUserJobTest`,
`…MetricsUnitTest`, `AdminTriggerTenantScopeUnitTest` and `WholeRunSuccessGaugeUnitTest` returns
nothing — every fixture sets a real tenant and a real warehouse.

**This also contradicts a claim in the PR description.** It says PIT ended with *"zero `NO_COVERAGE`
remaining"*. Mutants on an unreached branch are precisely `NO_COVERAGE`, and this branch is
unreached. Either the PIT run was scoped narrower than the sentence implies, or the finding was not
carried into the accepted-survivor list (which names only duration arithmetic, log conditionals,
`stopTenantTimer`/`TenantContext.clear()`, and the two boolean-return equivalents — not this).

`StaleClubBatchCleanupJobUnitTest:412` `malformedRowCostsOnlyItself` is the template and was written
for exactly this branch on the step-3 job. Cloning it, plus one assertion that the fleet gauge stays
zero, closes both the coverage gap and the undocumented divergence.

---

## M-2 (Medium) — the no-dual-lock argument reaches the right conclusion by the wrong route: `Pickingorder` is `@Version`-locked, and this javadoc is designated as the template for two more jobs

The class javadoc's first bullet (`:31-40`) argues:

> *"A second concurrent run … can only match rows the first hasn't committed yet, and **applying the
> same update twice converges to the same end state**."*

I verified the load-bearing half: `PickingorderRepository:91-100` really does filter
`WHERE po.lockedtooperator = true`, the exact column `releaseExpiredPickingOrders()` flips to
`false`. That part is correct.

What the argument omits is that `Pickingorder extends AbstractBaseEntity`, and
`AbstractBaseEntity:32-33` declares:

```java
@Version
private Integer version;
```

`releaseExpiredPickingOrders()` carries no `@Transactional`, so the query's session closes and the
entities come back **detached**; each `pickingorderRepository.save(pickingOrder)` is therefore a
`merge` that re-checks the version. Two runs that both read the row at version *v* do not both
succeed — the second raises an optimistic-lock failure. Concretely, in the rolling-deploy window the
javadoc is reasoning about:

- the exception propagates out of `releaseExpiredPickingOrders()`,
- **aborting the remaining rows in that tenant's list for the occurrence**,
- and lands in `runFor()`'s per-tenant `catch` (`:180-183`) → `tenantFailure(tenant, "…")` +
  `anyFailure = true` → `markLastSuccess()` withheld for the whole fire.

So "converges to the same end state" is true of the *database* and false of the *run*. The
observable drain-window signature is per-tenant failure counters and a stale freshness gauge, not
silence. Self-healing (the cron is every minute), but it is the opposite of what an operator reading
this javadoc would expect to see, and PR #291's review already established that undisclosed
drain-window metric movement is the kind of thing that has to be written down.

**The `@Version` finding cuts the other way too, and this is the part worth preserving.** I went
looking for a scenario where a concurrent double-run corrupts data and found the obvious candidate:

1. runs A and B both read order X at version *v* (`lockedtooperator = true`, `operatorId = 42`);
2. A commits the release — version *v+1*, `operatorId = null`;
3. operator Bob claims X — version *v+2*, `operatorId = 99`, `lockedtooperator = true`;
4. B saves its stale copy — **re-releasing an order a live operator is holding.**

Step 4 is a genuine lost-update, and it is `@Version` — not the `lockedtooperator = true` predicate —
that stops it. The predicate only proves B *selected* a row it was entitled to select; it says
nothing about what happened between B's select and B's save.

**Why this is Medium and not Low.** The javadoc states (`:49-50`) that this shape *"sets the
template"* for `OrderReleaseJob` and `ReplenishOrderJob` in step 5 parts 3-4. Neither of those is a
single-column flip on a version-locked entity, and "it's a plain `UPDATE`, so it converges" is a
one-line test that both would pass while being materially less safe. The decision to skip the
dual-lock here should be recorded as resting on **`@Version` + the self-selecting predicate**, with
the drain-window failure-counter consequence stated — otherwise the next two conversions inherit a
rule of thumb that does not generalise.

---

## L-1 (Low) — a two-key lock-busy tenant is entirely invisible in metrics, while `markLastSuccess()` still fires; the cited precedent has no metrics at all

`ReleaseExpiredPickingOrdersFromUserJobMetricsUnitTest`'s reworked AC-3 asserts, for a fleet whose
only tenant is lock-busy:

```java
assertThat(registry.find("…skipped_lock_busy").counter()).isNull();
assertThat(registry.find("…success").counter()).isNull();
assertThat(registry.find("…tenant_duration").timer()).isNull();
assertThat(registry.find("…last_success_epoch_seconds").gauge().value()).isGreaterThan(0);
```

That is an accurate description of the code, and I agree it is the right test. But read as a whole:
a tenant skipped for lock-busy produces **no counter, no timer, no failure, and no gauge movement**,
and the occurrence still reports fleet success. A per-tenant two-key lock that is stuck (a wedged
connection holding a session-level advisory lock) means that tenant is never processed and nothing
anywhere says so.

The test's justification is that this *"match[es] `StaleClubBatchCleanupJob`'s precedent, whose
two-key busy path is likewise metric-silent."* `grep -n "jobMetrics\|JobMetrics"
StaleClubBatchCleanupJob.java` returns exactly one line — a javadoc note that the job *"has no
`JobMetrics` at all"*. A job with no metrics cannot be a precedent for a metrics-bearing job
deliberately declining to emit one. The closer comparators are `CleanUpOldMessagesJob` and
`StockSummaryExportJob`, and in both a lock-busy tenant is at least *partly* visible, because their
one-key layer calls `skippedLockBusy()`. This job has no one-key layer (correctly, per M-2), so it
has no partial visibility either.

Not a defect — `JobMetrics` has no per-tenant lock-busy counter and adding one is scope creep. The
narrow fix is to cite the right precedent and say plainly that a stuck per-tenant lock is
metric-invisible for this job.

---

## L-2 (Low) — inside `runFor()`, the malformed-row and int4-overflow branches get opposite gauge treatment for the same class of defect, with no comment saying why

Both branches mean "this tenant is skipped **every occurrence** until a human edits the landlord
row". They are treated differently:

| Branch | Line | Sets `anyFailure`? | `markLastSuccess()` |
|---|---|---|---|
| malformed row (null tenant / blank warehouse) | `:131-134` | **yes** | withheld |
| `tenant_db_configuration.id` does not fit int4 | `:146-151` | no | still fires |

`CleanUpOldMessagesJob` is internally consistent here (neither feeds `anyFailure`), and
`StaleClubBatchCleanupJob:184-188` carries an explicit `L-3 (review)` comment explaining *why* its
int4 branch deliberately does not set the flag — reasoning that does not transfer to this job,
because this job has no `anyMember` concept. Neither the comment nor a replacement was carried over,
so the asymmetry reads as an oversight whether or not it is one. One sentence at `:150` resolves it.

---

## L-3 (Low) — the PR description's `NeverMatcher` census contradicts the census in the code it describes

PR body: *"census: 156→163 across 39 classes, +7"*.

The code says 154→163. Summing `PRIMITIVE_MATCHER_INVENTORY` on both sides of the diff:

```
OLD entries: 39   OLD sum: 154
NEW entries: 39   NEW sum: 163
```

The delta is **+9**, not +7: `AdminTriggerTenantScopeUnitTest` 2→4 and
`ReleaseExpiredPickingOrdersFromUserJobTest` 2→9. Both per-class numbers are correct — I recounted
all seven new occurrences by hand (`:467` one `anyLong()`; `:497`, `:511`, `:527` two each) and both
pre-existing `anyInt()` sites (`:199`, `:218`). **The code is right and the prose is wrong**, which
is the harmless direction, but this is the same finding PR #291's review filed as its L-3 — second
occurrence, same field, so it is worth fixing the habit rather than the number.

---

## L-4 (Low) — `AdminActionController:162` now describes this handler using a method this PR deleted

The comment block immediately above `triggerReleaseExpiredPickingOrdersFromUser` reads:

> *"Current contract, per Nam's Option A decision: **`doCalculation(false)`** acts on the CALLER'S
> tenant only. The four jobs that ignored the flag now resolve `TenantContext.getCurrentTenant()`…"*

For this handler, `doCalculation(false)` no longer exists — the call four lines below is
`runForCurrentTenant()`. The block is shared preamble and remains accurate for the two unconverted
jobs, but it sits directly above the one handler it no longer describes, and the same block opens by
promising *"Superseded text is not left here."* The PR added a correct `✅ RESOLVED 2026-09-03`
paragraph underneath without updating the paragraph above it. Steps 5 parts 3-4 will delete the last
two `doCalculation` callers; this sentence should be rewritten now rather than left to rot for two
more PRs.

---

## L-5 (Low) — `adminTrigger_leavesTheCallersContextIntact` silently exercises the exception path, not the success path it reads as testing

`AdminTriggerTenantScopeUnitTest:515-532` stubs `callerResolvesToLandlordRow(2L)` (landlord lookup +
`tryLock` → true) and nothing else. The class is `@MockitoSettings(strictness =
Strictness.STRICT_STUBS)` (`:144`), so the unstubbed
`getSysvalue(PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE_KEY)` returns `null`, `Integer.parseInt(null)`
throws `NumberFormatException`, `runForCurrentTenant()`'s `catch` swallows it and returns `false` —
and the return value is discarded, so nothing notices.

The assertion still holds something real (the `finally` must not clear `TenantContext` on the
*failure* path either), and the sibling `CleanUpOldMessages` nested class likely has the same shape.
But the test's name and its `.as(…)` message describe the two-jobs-in-sequence success scenario, and
it does not cover it. Adding the timeout-value stub and `assertThat(ran).isTrue()` costs two lines
and makes the test test what it says.

---

## Verified — what I tried to break and could not

- **Lock acquire/release pairing in `runFor()`'s per-tenant loop (review question 1).** No leak on
  any path. `tryLock` → `true` is immediately followed by a `try` whose `finally` unlocks (`:158-179`),
  so the release covers the activation-skip `continue`, the success path, and any throw from
  `releaseExpiredPickingOrders()`. The `continue`s *above* the `tryLock` (malformed row, int4
  overflow) run before any acquisition. A `tryLock` that itself throws leaves nothing held and is
  caught at `:180`. `startTenantTimer()` is deliberately the **first** statement inside the
  lock-releasing `try` — the L-1 placement PR #291's review assigned to this clone — so even the
  unreachable case of `Timer.start()` throwing releases the lock. Mutant A killed by two tests.
- **`runForCurrentTenant()`'s outcome paths (review question 2).** All five are correct and the lock
  is released in exactly the cases it was taken. The three pre-lock refusals (`:221`, `:228`, `:236`)
  return before any acquisition — and `refusesWithNoLandlordRow` / `refusesOnInt4Overflow` both pin
  that with `never().tryLock(anyLong(), anyLong())`, so a "tidy the guards below the lock" edit is
  caught. The lock-busy refusal (`:241-245`) returns without unlocking, pinned by
  `never().unlock(anyLong(), anyLong())` (mutant C killed there). Success and exception both fall
  through the shared `finally` at `:252-254`. Note `AdvisoryLockService.unlock` is idempotent-safe
  anyway (it warns and returns on a null pinned connection), but the code does not lean on that.
- **`runForCurrentTenant()` does not clear `TenantContext`.** Correct and load-bearing:
  `AdminActionController.triggerOrderReplenish` calls two jobs in sequence, and clearing here would
  make the second refuse. Pinned (weakly — see L-5).
- **Claim 4 — no `TriggerSpec`/group derivation (review question 4).**
  `configureReleaseExpiredPickingOrdersFromUser:942-957` hardcodes `"40 * * * * *"` and reads exactly
  one sysprop, `CRON_JOB_SHOW_LOG_KEY`, which is a global log-verbosity flag, not a schedule. It is
  registered through `onlyIfMissing(…)` alongside `orderRelease`/`replenish`, not through a
  `configure…Groups` path. Only the fire handler changed. The claim holds exactly as stated.
- **Claim 5 — `skippedLockBusy()` never called (review question 5).** `grep -rn "skippedLockBusy()"
  src/main` finds four call sites, none in this job. All four sit on a **one-key** busy path, which
  this job does not have — so the divergence is structural, not a forgotten call. (The precedent is
  cited to the wrong sibling; see L-1.)
- **`NeverMatcherNullBlindnessArchTest` census (review question 7).** Arithmetically correct in both
  directions and per class. The count is 9 for `ReleaseExpiredPickingOrdersFromUserJobTest` and 4 for
  `AdminTriggerTenantScopeUnitTest`, hand-counted from the actual call sites, and the inventory sums
  to 163 over 39 classes. `eq(…)` correctly not counted at `:467`; bare `any()` correctly not counted
  at `:200`, `:219`, `:263`.
- **`anyLong()` inside `never()` is safe here.** The `tryLock`/`unlock` two-key overloads declare
  `(long, long)` primitives, so the `any()`-returns-null unboxing NPE does not apply and the
  primitive-capable matcher is the correct choice, not a null-blind one.
- **Full suite (review question 8).** `6262/0/0/67`, BUILD SUCCESS — reproduces the PR's claim
  exactly, and is +10 over the 6252 post-#291 baseline as stated.
- **Both production callers are converted and no third exists.** `grep -rn
  "releaseExpiredPickingOrdersFromUserJob\." src/main` → `SchedulingConfiguration:950` (`runFor()`)
  and `AdminActionController:180` (`runForCurrentTenant()`). The `@Disabled` duplicate-pair partner
  `ReleaseExpiredPickingOrdersFromUserJobUnitTest` was compile-fixed only, as claimed.
- **`AdminActionController` surfaces the real outcome.** `ResponseEntity.ok(ran)` replaces
  `ok(true)`, and `surfacesRefusalInsteadOfHardcodedSuccess` pins the `false` case as body text —
  a revert to the hardcoded literal is caught.
- **`WholeRunSuccessGaugeUnitTest`'s empty-fleet test correctly dropped its lock stub.** With zero
  active tenants `runFor()` returns before any lock attempt, so under `STRICT_STUBS` keeping the stub
  would have failed. The removal is right, not a weakening.
- **`JobLockId.RELEASE_EXPIRED_PICKING = 100005L`** fits int4 comfortably, so the two-key form's own
  internal `Math.toIntExact(jobLockId)` can only ever throw on the tenant id — which is why the job's
  pre-check is on the tenant id alone. Correct.

---

## Recommended pre-merge set

1. **H-1** — decide whether the manual path keeps its activation gate. Either way: fix the
   `runForCurrentTenant()` javadoc parenthetical (it is false as written), disclose the change in the
   PR description, and add a test pinning the chosen behaviour with
   `PICK_TIME_OUT_SYSTEM_ACTIVATED = false`.
2. **M-1** — clone `StaleClubBatchCleanupJobUnitTest.malformedRowCostsOnlyItself` for this job and
   assert the fleet gauge stays zero, so `anyFailure = true` is pinned; and correct the PR
   description's `NO_COVERAGE` claim.
3. **M-2** — rewrite the no-dual-lock bullet to rest on `@Version` + the self-selecting predicate,
   and state the drain-window consequence (optimistic-lock failure → `tenant_failure` +
   `markLastSuccess()` withheld, self-healing next minute). This is the bullet steps 5 parts 3-4 will
   clone.
4. **L-1 … L-5** — one-line fixes each: cite the right lock-busy precedent; add the missing
   `anyFailure` asymmetry comment; correct the PR body's `156→163`; rewrite
   `AdminActionController:162`'s `doCalculation(false)` sentence; add the two missing lines to
   `adminTrigger_leavesTheCallersContextIntact`.
