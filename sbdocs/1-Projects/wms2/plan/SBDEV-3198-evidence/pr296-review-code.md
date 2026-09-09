---
title: PR #296 independent code review — restore CleanUpOldMessagesJob's manual-trigger activation gate
description: Adversarial code-correctness review of wms2-api PR #296 (SBDEV-3198 follow-up) at head e7c844b7, verifying the historical claim, the restored gate's placement, all six touched tests, and the PIT/suite claims by hand mutation
ticket: SBDEV-3198
pr: 296
reviewed_commit: e7c844b7
base: 56fc1035
date: 2026-09-03
status: reviewed
---

# PR #296 — independent code review

**Verdict: APPROVE with minor findings.** The bug is real, the historical claim the fix rests on is
true (independently verified against `e83d9550`), the restored check is correctly placed and
correctly releases the lock, and the fix is genuinely covered — every non-equivalent mutation of
`runForCurrentTenant()`'s activation-and-return logic is killed by an assertion. Nothing here blocks
merge.

The findings are one test-robustness gap and three documentation-accuracy defects. The Medium
matters more than its severity suggests: it is the *same* failure class PR #293's round 2 filed as
N-2, reproduced inside the test written to prevent it — and this file's javadoc is the template the
three remaining D′ conversions will be cloned from.

| Severity | Count |
|---|---|
| High | 0 |
| **Medium** | **1** (M-1) |
| **Low** | **3** (L-1, L-2, L-3) |
| Note | 2 (N-1, N-2) |

---

## Evidence collected

Every row below was run by me in
`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-296-review-code`, detached at
`e7c844b7`, restored to pristine (`git status --porcelain` empty) after each mutation.

| Instrument | Result |
|---|---|
| `git show e83d9550:…/CleanUpOldMessagesJob.java` | **PR's historical claim CONFIRMED.** `:89` `tenantProfiles = List.of(callerTenant)` (manual path) feeds the *same* loop whose body at `:101-107` is the two-flag activation gate + `tenantSkippedNotActivated` + `continue`. The pre-D′ manual trigger WAS activation-gated |
| `git show e83d9550:…/StockSummaryExportJob.java:99-152` | **Sibling is genuinely different** — its manual path is a separate `else` branch calling `exportStockSummary(null)` directly, with no gate. The "activation-flag-free" premise was TRUE for the job this one was templated from. Explains the defect's origin exactly; confirms the fix must NOT be applied to `StockSummaryExportJob` |
| `mvn -o clean test` (full suite, HEAD `e7c844b7`) | **6265 run, 0 failures, 0 errors, 67 skipped — BUILD SUCCESS.** Matches the PR's claim exactly |
| PIT, `targetClasses=…CleanUpOldMessagesJob` over 5 test classes | **56 mutations, 47 killed = 84%.** Matches the PR's claim exactly. 8 SURVIVED + 1 NO_COVERAGE |
| PIT survivor triage (`mutations.xml`) | 5 survivors + the 1 NO_COVERAGE are all in `runFor()` (scheduled path, untouched by this diff) — **pre-existing, confirmed**. The 3 in `runForCurrentTenant()` are **equivalent mutants**, see L-1 |
| Hand mutant **M1** — delete the restored activation `if` (`:353-358`) | **KILLED on assertions.** 26 run, **2 Failures**, 5 Errors. `refusesWhenNotActivated:213` and `refusesWhenGlobalCronSwitchOff:230` both fail with `AssertionFailedError: Expecting value to be false but was true`. **No repeat of PR #293's N-2** |
| Hand mutant **M2** — second key → duplicate of `NEW_CRON_JOB_ACTIVATED_KEY` | **KILLED on an assertion.** 1 Failure: `refusesWhenNotActivated:213`. The *right* second sysprop key is genuinely pinned |
| Hand mutant **M3** — drop the `NEW_CRON_JOB_ACTIVATED_KEY` clause entirely | **KILLED, but by ZERO assertions.** 26 run, **0 Failures**, 6 Errors — all Mockito strictness (`UnnecessaryStubbing`, and `PotentialStubbingProblem` at `refusesWhenGlobalCronSwitchOff:228`). **See M-1** |
| Hand mutant **M5** — success path `return true` → `return false` | **KILLED on assertions.** 26 run, **4 Failures, 0 Errors**: `adminTrigger_leavesTheCallersContextIntact:334`, `adminTrigger_runsOnlyTheCallersTenant:290`, `doesNotTouchTheWholeRunGauges:294`, `locksOnTheCallersOwnTenantId:276`. All four "fixed" tests genuinely reach the success path |
| M-1's proposed remedy, on **unmutated** code | `CleanUpOldMessagesJobUnitTest`: 10 run, 0 failures — **stays green** |
| M-1's proposed remedy, **+ M3** | **1 Failure: `refusesWhenGlobalCronSwitchOff:233`**, `AssertionFailedError: Expecting value to be false but was true`. Remedy verified to close the gap |
| `git diff --stat 56fc1035 e7c844b7` | Exactly **3 files**: the job + its two directly-affected test classes. **Scope claim holds** |
| `grep -rn runForCurrentTenant src/test/` | Every other caller is `StockSummaryExportJob`'s or a *mocked* controller test. The 5-test surgery list is complete — no silently-drifted test elsewhere |
| `AdminActionController.java:125-127` | `@RequiresFunction(WEB_UI_VIEW_IMPORT_DATA)` on `@GetMapping("/triggerArchiveMessages")`, class `@RequestMapping("/v3/adminAction")`. The PR's endpoint path and live-consequence framing are accurate |
| `git rev-list --count 56fc1035..origin/develop` | **8** — see N-1 |

---

## M-1 (Medium) — `refusesWhenGlobalCronSwitchOff` does not kill its own mutant on its own assertion

This is the one finding I would want fixed before merge, because of what it is rather than what it
costs.

`refusesWhenGlobalCronSwitchOff` exists to pin one thing: that the global cron kill switch
(`SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY`) is part of the restored condition. I deleted exactly
that clause (M3, leaving only `CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY`) and ran both test classes:

```
[ERROR] Tests run: 26, Failures: 0, Errors: 6, Skipped: 2
```

**Zero assertion failures.** `refusesWhenGlobalCronSwitchOff`'s own three assertions
(`assertThat(ran).isFalse()`, `never()).archiveMessage()`, `verify(...).unlock(...)`) all still hold
under the mutant, because the now-unstubbed `CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY` returns `null`,
`Boolean.parseBoolean(null)` is `false`, and the method refuses anyway. The test dies only on
`org.mockito.exceptions.misusing.PotentialStubbingProblem` — Mockito noticing the stubbed key is
never the one read.

That is precisely the mechanism PR #293's round-2 review filed as **N-2**, and the reason it matters
is written in that report: *"the natural remedy for that error message is to delete the stub, which
is exactly what the pre-fix author did."* A future engineer who touches this condition sees a
Mockito plumbing error, not a failed assertion, and the documented-in-repo reflex is to relax or
delete the stub — silently removing the only pin on the global kill switch.

The in-test comment is what locks the gap in place:

```java
// The `||` short-circuits on this flag alone, so CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY is
// never read here — stubbing it would be an UnnecessaryStubbing under STRICT_STUBS.
```

True as written, and it correctly explains why the obvious fix does not work — but it concludes
"therefore don't stub it" when the right conclusion is "therefore stub it *leniently*".

**Verified remedy** (I ran both halves):

```java
when(syspropService2.getSysvalue(WmsConstants.SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY))
        .thenReturn("false");
// lenient: the `||` short-circuits so correct code never reads this key. Stubbing it
// ANYWAY (leniently) is what makes this test kill the "dropped the global-switch
// clause" mutant on its OWN assertion instead of on Mockito strictness plumbing.
lenient().when(syspropService2.getSysvalue(WmsConstants.SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY))
        .thenReturn("true");
```

- On unmutated code: `CleanUpOldMessagesJobUnitTest` **10 run, 0 failures** — `lenient()` absorbs the
  unused stub, so the test stays green and STRICT_STUBS stays on for everything else.
- With M3 applied: **1 Failure at `refusesWhenGlobalCronSwitchOff:233`** —
  `AssertionFailedError: Expecting value to be false but was true`. The mutant now dies on the
  test's own assertion.

`lenient()` is already statically imported in this file (`import static org.mockito.Mockito.*`), so
this is a 4-line change with no other edits.

Note that `refusesWhenNotActivated` does **not** have this problem — M1 and M2 both kill it on
`assertThat(ran).isFalse()`. The gap is specific to the short-circuited clause.

---

## L-1 (Low) — the PR's PIT justification states a mechanism that is false, and undersells the result

The PR body explains `runForCurrentTenant()`'s three residual survivors as:

> `runForCurrentTenant()`'s three return statements sit inside a try/finally the compiler duplicates
> per exit path, which PIT's own automated run also flagged as 3 residual survivors here — same
> accepted class as `ReleaseExpiredPickingOrdersFromUserJob`'s PR #293.

That is not the mechanism. Pulling every mutation PIT generated on those three lines:

| Line | Source | `→ false` mutator | `→ true` mutator |
|---|---|---|---|
| 357 | `return false;` (not-activated) | **SURVIVED** (identity) | **KILLED** |
| 360 | `return true;` (success) | **KILLED** | **SURVIVED** (identity) |
| 363 | `return false;` (catch) | **SURVIVED** (identity) | **KILLED** |

PIT runs `BooleanTrueReturnVals` *and* `BooleanFalseReturnVals` at every boolean return, so one of
each pair is always a no-op rewrite of the literal that is already there. The three survivors are
**equivalent mutants** — unkillable by any test, by construction — and have nothing to do with
try/finally duplication.

The correction is favourable to the PR: **every non-equivalent return mutation on this method is
killed**, so return coverage here is not merely "acceptable with residuals", it is complete. My M5
run confirms it independently.

Worth fixing rather than shrugging at, for one reason: this sentence is offered as an "accepted
class" precedent, in the file that is the stated template for the three remaining conversions. A
wrong mechanism generalises into a licence to wave away future survivors that are *not* equivalent.

---

## L-2 (Low) — the PR body says "Four existing tests", then lists five

> **Four existing tests** assumed the buggy (no-check) behaviour and needed activation stubs added…

The list under it names five, and the diff adds activation stubs to five:
`returnsFalseAndStillUnlocksWhenArchiveThrows`, `locksOnTheCallersOwnTenantId`,
`doesNotTouchTheWholeRunGauges`, `adminTrigger_runsOnlyTheCallersTenant`,
`adminTrigger_leavesTheCallersContextIntact`. The count, not the list, is wrong. PR body only — no
code change.

(The "4 tests fail" hand-mutation claim elsewhere in the PR body is separately correct: M5 fails
exactly four, because the fifth is an exception-path test that expects `false` regardless.)

---

## L-3 (Low) — the not-activated refusal drops from INFO to DEBUG, on a path the PR itself documents as metric-invisible

`:355` logs the refusal at **DEBUG**. Both of its references log it at **INFO**:

- `runFor():237` — `LOG.info("{} not activated for {} - {}", …)` plus
  `jobMetrics.tenantSkippedNotActivated(tenantName)`.
- pre-D′ `e83d9550:104` — `LOG.info("cleanUpOldMessagesJob not activated for for {} - {}", …)`, on
  this very manual path.

The method javadoc explicitly and deliberately records that this path touches **no** `JobMetrics` of
any kind (correctly adopting PR #293's N-3 remedy ahead of that PR landing — good). But that
decision was justified on the grounds that the *gauges* would mislead fleet alerting, and it leaves
observability resting entirely on the log line — which is then emitted below the default INFO
threshold. Net effect in production: an admin clicks "run now" on a deactivated tenant, receives
`HTTP 200` with body `false`, and **no log line and no metric records that it happened**.

`ERROR` is used for the other refusals in this method (no context, no landlord row, non-int4 id);
`DEBUG` is used for lock-busy. Not-activated is the one refusal an operator is most likely to have
caused on purpose and most likely to ask about, and it is the quietest.

Suggest `LOG.info` here, matching both `runFor()` and the pre-D′ behaviour the rest of this PR is at
pains to restore. One-word change. If DEBUG is deliberate, the javadoc's metrics paragraph is the
place to say so, since it already reasons about this exact outcome's visibility.

---

## N-1 (Note) — branch base is 8 commits behind `origin/develop`; no overlap, so the suite figure stands

`merge-base` is `56fc1035`; `origin/develop` is now `dd0f79c7`, 8 commits ahead (PRs #294, #295 —
SBDEV-3158 masterdata gating and SBDEV-3183 item-verb residuals). Those commits touch only
`RestConfiguration`, seven `*Controller` classes, and three `security/` test classes — **zero**
overlap with `schedulejob/`. So there is no merge hazard and the 6265/0/0/67 figure remains
representative of the merged result. Recorded only because the number was measured pre-merge.

## N-2 (Note) — the javadoc forward-references an unmerged PR's finding number

`:305-308` cites "SBDEV-3198 step 5 part 2's N-3 finding". PR #293 is not yet on `develop` (its job,
`ReleaseExpiredPickingOrdersFromUserJob`, still has `doCalculation(Boolean)` at this base). Harmless
if #293 lands first or at all; worth a glance at merge order so the reference does not dangle.

---

## Verified — what I tried to break and could not

**The historical claim, checked at source rather than taken on trust.** This was the PR's load-bearing
assertion and the thing two prior review rounds missed. `git show e83d9550` shows the manual path
(`tenantProfiles = List.of(callerTenant)`) entering the same `for` loop as the scheduled path, whose
body opens with the two-flag gate and `continue`. There is no second, ungated path. The claim is
true, and the D′ conversion did silently drop the gate.

**The sibling sweep — and the negative result that explains the defect.** I checked whether the same
fix is owed to `StockSummaryExportJob`, whose `runForCurrentTenant()` has no activation check. It is
not: at `e83d9550` that job's manual trigger was a genuinely separate `else` branch calling
`exportStockSummary(null)` directly, with no gate anywhere near it. The "activation-flag-free"
premise was *true* for the job this one was templated from — which is exactly how a correct comment
became a false one when copied one file over. The fix is correctly scoped to this job alone.

**Forward exposure of the same trap.** `OrderReleaseJob:110-125`, `ReplenishOrderJob:143-159` and
`ReleaseExpiredPickingOrdersFromUserJob:99-114` all still route `List.of(callerTenant)` through their
gated shared loop. All three will hit this identical trap when steps 5 parts 2–4 convert them. This
PR's javadoc is the right place for that warning and it is there — the mechanism is stated, not just
the outcome.

**Placement, ordering, and lock release.** The check sits at `:353-358`, inside the `try` at `:348`
whose `finally` at `:364-366` unlocks — after `tryLock`, before `archiveOldMessages()`, the same
relative position `runFor()` uses (`:235-241`, inside its own two-key lock's `try`). Same two
`WmsConstants` keys, same order, same `||` polarity. The not-activated `return false` at `:357`
passes through the `finally`, so the lock is released — pinned by both new tests'
`verify(advisoryLockService2).unlock(CLEAN_UP_MESSAGES, 1L)`, and M2/M3 confirm those `verify`s are
live rather than vacuous.

**Every touched test actually reaches the path it claims.** M5 (`return true` → `return false`) fails
exactly four tests, all as assertion `Failures` with zero errors — so
`adminTrigger_runsOnlyTheCallersTenant`, `adminTrigger_leavesTheCallersContextIntact`,
`locksOnTheCallersOwnTenantId` and `doesNotTouchTheWholeRunGauges` all genuinely execute the success
path rather than silently refusing. `adminTrigger_leavesTheCallersContextIntact` is the strongest
improvement in the diff: it previously discarded the return value entirely (PR #293's L-5 pattern),
and now captures and asserts it. The fifth surgery target,
`returnsFalseAndStillUnlocksWhenArchiveThrows`, correctly does *not* fail under M5 — it expects
`false` either way — but M1 proves its new stubs are genuinely consumed (they become
`UnnecessaryStubbing` the instant the gate is removed), so it too now passes *through* the gate
rather than being refused by it.

**The specific failure mode I was asked to hunt for did not recur in `refusesWhenNotActivated`.** PR
#293's N-2 was a not-activated test that passed under mutation because downstream code threw on an
unstubbed sysprop. That cannot happen here: `archiveOldMessages()` calls only the mocked
`cleanUpOldMessageJobService.archiveMessage()` and reads no sysprops. M1 confirms empirically —
`refusesWhenNotActivated` fails on `assertThat(ran).isFalse()`, not on an exception. It also survives
M2 correctly. (The sibling gap that *does* exist is confined to the short-circuited clause — M-1.)

**Scope.** Three files, all named in the PR. No drive-by edits, no unrelated refactoring, no changes
to `runFor()`, `AdminActionController`, `WmsConstants`, or `StockSummaryExportJob`. The class-javadoc
edit rewrites only the false "preserving the activation-flag-free … behaviour" clause it needed to
correct.

**Both claimed numbers reproduce exactly** — 6265/0/0/67 and PIT 84% — on my own runs, not read from
the PR.
