---
title: PR #296 independent code review, round 2 — restore CleanUpOldMessagesJob's manual-trigger activation gate
description: Round-2 adversarial code-correctness review of wms2-api PR #296 at head 7edd47d2, verifying round 1's M-1/L-1/L-2/L-3 fixes by hand mutation rather than by reading, plus a fresh end-to-end pass over the whole diff
ticket: SBDEV-3198
pr: 296
reviewed_commit: 7edd47d2
previous_round_commit: e7c844b7
base: 56fc1035
date: 2026-09-03
status: reviewed
---

# PR #296 — independent code review, round 2

**Verdict: APPROVE.** All four round-1 findings are genuinely closed, and the one that mattered
(M-1) is closed *correctly* — I re-applied the exact mutant round 1 used to expose it and the test
now dies on its own `AssertionFailedError`, not on Mockito plumbing. The remedy is scoped to a
single stubbing and demonstrably does **not** weaken `STRICT_STUBS` anywhere else in the class. The
fix pass introduced no behavioural change beyond a log level, and no new correctness defect.

Two new findings, both Low, both documentation/observability hygiene rather than correctness — and
one of them exists *because* of the fix pass, which is exactly the class of thing a round 2 is for.
Neither blocks merge.

| Severity | Count | IDs |
|---|---|---|
| High | 0 | — |
| Medium | 0 | — |
| **Low** | **2** | R2-L-1, R2-L-2 |
| Note | 2 | R2-N-1, R2-N-2 |

Round-1 findings: **M-1 closed, L-1 closed, L-2 closed, L-3 closed.** Details in the last section.

---

## Evidence collected

Every row was run by me in
`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-296-review2-code`, detached at
`7edd47d2`, restored to pristine (`git status --porcelain` empty) after each mutation. Mutation runs
and the full-suite run were kept strictly sequential — one Maven per worktree, per this repo's
known false-red trap.

| Instrument | Result |
|---|---|
| Hand mutant **M3′** — delete the global-cron-switch clause from the restored gate (round 1's M3, re-applied at the fixed head) | **KILLED ON ITS OWN ASSERTION.** 26 run, **1 Failure**, 6 Errors. `refusesWhenGlobalCronSwitchOff:236` — `AssertionFailedError: Expecting value to be false but was true`. Round 1 measured **0 Failures** on this same mutant. **M-1 verified closed** |
| Hand mutant **M6** — `\|\|` → `&&` in the restored gate (a mutant no round has tried) | **KILLED ON ASSERTIONS.** 26 run, **2 Failures**: `refusesWhenGlobalCronSwitchOff:236` and `refusesWhenNotActivated:213`, both `Expecting value to be false but was true`. The lenient stub is what makes the first of these two fire — without a `CLEAN_UP…=true` stub the unstubbed key returns `null`, `parseBoolean(null)` is `false`, and the `&&` mutant would still refuse. **The M-1 remedy strengthens coverage against a second mutant class round 1 never measured** |
| `STRICT_STUBS` still live in the same class (empirical, from the M3′ run) | Under M3′, **five other tests in the two touched classes raised `UnnecessaryStubbing`** — `refusesWhenNotActivated`, `locksOnTheCallersOwnTenantId`, `doesNotTouchTheWholeRunGauges`, `returnsFalseAndStillUnlocksWhenArchiveThrows`, and both `AdminTrigger…` tests. Strictness is unimpaired; the `lenient()` is stubbing-scoped |
| `grep -n "lenient" CleanUpOldMessagesJobUnitTest.java` | Exactly **two** sites: the pre-existing `:144` `findByTenantNameAndWarehouse` setUp stub, and the new `:231`. No third, no class-level relaxation |
| `grep -n "MockitoSettings\|Strictness\."` on both touched test classes | `@MockitoSettings(strictness = Strictness.STRICT_STUBS)` at `CleanUpOldMessagesJobUnitTest:120` and `AdminTriggerTenantScopeUnitTest:144` — **unchanged by the fix diff** (`git diff e7c844b7..7edd47d2` touches neither line) |
| `git show e83d9550:…/CleanUpOldMessagesJob.java` (pre-D′), log line at the gate | `LOG.info("cleanUpOldMessagesJob not activated for for {} - {}", …)` — **INFO**. **L-3's premise confirmed independently** |
| `runFor()`'s equivalent line, current head `:237` | `LOG.info("{} not activated for {} - {}", …)` — **INFO**. The fixed manual path now matches both references |
| Hand mutant **M1′** — delete the restored activation `if` entirely (round 1's M1, re-applied at the fixed head) | **STILL KILLED ON ASSERTIONS.** 26 run, **2 Failures**, 5 Errors: `refusesWhenGlobalCronSwitchOff:236` and `refusesWhenNotActivated:213`, both `Expecting value to be false but was true`. The lenient stub did not degrade round 1's existing kill |
| `mvn -o clean test` (full suite, HEAD `7edd47d2`) | **6265 run, 0 failures, 0 errors, 67 skipped — BUILD SUCCESS.** Identical to round 1's figure at `e7c844b7` and to the PR's claim, as expected for doc/log-level/test-only fixes |
| `git diff e7c844b7..7edd47d2 --stat` | **2 files, 14 insertions, 3 deletions.** Job class: log level + a 5-line comment. Test class: a lenient stub + a rewritten comment. **No third file, no behavioural change beyond the log level** |
| `git diff 56fc1035..7edd47d2 --stat` (whole PR) | **3 files, 108 insertions, 14 deletions** — the job and its two directly-affected test classes. Scope claim still holds at the fixed head |
| `grep -rn runForCurrentTenant src/main` | Two callers of *this* job's method: `AdminActionController:131` only. `StockCountRestController:111` and `AdminActionController:121` are `StockSummaryExportJob`'s — the sibling round 1 correctly excluded |
| `grep -rln CleanUpOldMessagesJob src/test` | 10 classes. Of these only `CleanUpOldMessagesJobUnitTest` and `AdminTriggerTenantScopeUnitTest` call `runForCurrentTenant()` un-mocked; `AdminActionControllerUnitTest:172/186` stubs it; the near-duplicate `CleanUpOldMessagesJobTest` exercises **only** `runFor(...)` (verified by reading all 12 of its test method names). **No silently-drifted test elsewhere** |
| `git rev-list --count $(git merge-base HEAD origin/develop)..origin/develop` | **12** (was 8 at round 1) — see R2-N-1 |
| `grep -rln ListAppender src/test` | **11 classes**, two of them sibling `schedulejob/` job tests — see R2-L-1 |
| Current line numbers of `runForCurrentTenant()`'s three boolean returns | `:362`, `:365`, `:368` at `7edd47d2`; `:357`, `:360`, `:363` at `e7c844b7`. See R2-L-2 |

---

## R2-L-1 (Low, NEW) — the log level L-3 restored is the only observability for this refusal, and nothing pins it

This is the finding I would most want addressed, and it exists *because* round 1's fix landed.

The L-3 fix is correct — I verified the premise at source, not from the report: pre-D′ `e83d9550`
logged this refusal at `LOG.info`, `runFor():237` logs its equivalent at `LOG.info`, and the manual
path now does too. The in-code comment justifying it is accurate.

But read the justification the fix itself writes into the source:

> This method deliberately touches no JobMetrics (class javadoc), so the log line is the ONLY
> observability this refusal has

That is a statement that this single word is load-bearing. And **no test asserts it.** A future
"these job logs are too chatty at INFO" sweep — precisely the kind of edit that produced the original
D′ defect this whole PR exists to repair — flips it back to `LOG.debug` with a fully green build, and
the only record that it mattered is a source comment, which is what failed last time.

The remedy is available and already in use in this exact package. `ListAppender` appears in **11**
test classes, including two `schedulejob/` siblings; `StaleClubBatchCleanupJobUnitTest` — another
SBDEV-3198-family job test — already carries a `messagesAt(Level.INFO)` helper (`:113-128`) and
asserts on it at `:217`, `:274`, `:426`, `:448`, `:472`. Adding a capture to
`refusesWhenNotActivated` asserting the refusal appears at `Level.INFO` is a handful of lines against
an established local pattern.

Low rather than Medium because it is observability, not behaviour: nothing archives or fails to
archive if this regresses. But the PR's own argument is what makes it worth pinning — a decision
defended in prose as "the ONLY observability" and then left unguarded is the same shape as the
javadoc claim that started this ticket.

---

## R2-L-2 (Low, NEW) — the PR body's PIT line-number citations went stale when the L-3 fix shifted them

The PR body, in the paragraph L-1's fix rewrote, cites:

> `runForCurrentTenant()`'s three return statements (`:357`, `:360`, `:363`) each show one SURVIVED
> mutant

Those were the correct line numbers at `e7c844b7`, the commit PIT was run against. The L-3 fix
inserted a five-line comment above the refusal `return`, so at the current head `7edd47d2` the three
returns are at **`:362`, `:365`, `:368`**. I checked both revisions directly rather than inferring
the offset.

Trivial in isolation. Worth the line because this PR body is the artifact three more D′ conversions
will be templated from, and this repo's fix discipline treats citation form as load-bearing —
a reviewer of step 5 part 3 who opens `:357` at the merged head lands on the `LOG.info` call inside
the comment block, not on a return statement. Either re-point the three numbers or drop them (the
mutator-pair explanation stands on its own without them). PR body only — no code change.

---

## R2-N-1 (Note) — base is now 12 commits behind `origin/develop`, still zero overlap

`merge-base` is still `56fc1035`; `origin/develop` is now 12 commits ahead (was 8 at round 1).
Those commits touch `RestConfiguration`, seven `*Controller` classes, and four `security/` test
classes — **zero** files under `schedulejob/`, and none of the three files this PR touches. No merge
hazard. The suite figure below is measured on the PR branch and is correct for it; the merged total
may be higher if any of those 12 commits added test classes, which is expected and not a discrepancy.

## R2-N-2 (Note) — round 1's N-2 forward reference is unchanged and still worth watching at merge

The method javadoc still cites "SBDEV-3198 step 5 part 2's N-3 finding" (PR #293), which is not yet
on `develop` — `ReleaseExpiredPickingOrdersFromUserJob` still carries `doCalculation(Boolean)` at
this base. Harmless either way; noted so merge order is a deliberate choice rather than an accident.
Carried forward from round 1, not re-litigated.

---

## Round-1 findings — resolved

Each verified by re-running the instrument, not by reading the fix.

### M-1 — CLOSED, and the remedy is better than round 1 measured

Round 1's complaint was that `refusesWhenGlobalCronSwitchOff` died on
`org.mockito.exceptions.misusing.PotentialStubbingProblem` rather than on its own assertion when the
global-cron-switch clause was deleted — the same failure class PR #293 filed as N-2, whose natural
remedy (delete the stub) silently re-opens the gap.

I re-applied that exact mutant at the fixed head:

```
[ERROR] Tests run: 26, Failures: 1, Errors: 6, Skipped: 2
[ERROR]   CleanUpOldMessagesJobUnitTest$RunForCurrentTenantLocking.refusesWhenGlobalCronSwitchOff:236
Expecting value to be false but was true
```

**One assertion failure where round 1 measured zero.** The test now kills its own mutant on
`assertThat(ran).isFalse()`. Closed.

The in-test comment was also rewritten, and correctly: the old version stated a true fact
("stubbing it would be an UnnecessaryStubbing") and drew the wrong conclusion from it; the new one
states the same fact and draws the right one, naming the failure mode it prevents. A future
engineer who hits the Mockito error now has the reason not to delete the stub written where they
will read it.

**No regression to round 1's existing kill.** The lenient stub could in principle have changed the
outcome of round 1's M1 (delete the whole gate), since it adds a second stub that becomes unused
under that mutant. It does not: M1 re-applied at the fixed head still produces **2 assertion
Failures**, the same two tests round 1 measured.

**Bonus not claimed by the fix:** the lenient stub also kills a mutant class round 1 never measured.
Under `||` → `&&`, correct-code-minus-the-stub would leave `CLEAN_UP…` unstubbed → `null` →
`parseBoolean` false → the method refuses anyway → test passes. With the stub returning `"true"`,
the `&&` mutant runs the archive and the assertion fires. Verified: 2 Failures, both
`AssertionFailedError`.

### L-1 — CLOSED

The PR body's PIT paragraph now reads "these are **equivalent mutants** (PIT runs both
`BooleanTrueReturnVals` and `BooleanFalseReturnVals` at every boolean return, so one of the pair is
always a no-op rewrite of the literal already there), not a coverage gap". The false try/finally
mechanism is gone from the claim; the only surviving occurrence of the phrase "try/finally" in the
body is inside the L-1 changelog entry describing the *old* wrong claim, which is the correct place
for it. (One residual: the line numbers in that same paragraph — R2-L-2.)

### L-2 — CLOSED

The body now says "**Five** existing tests assumed the buggy (no-check) behaviour" and lists five:
`returnsFalseAndStillUnlocksWhenArchiveThrows`, `locksOnTheCallersOwnTenantId`,
`doesNotTouchTheWholeRunGauges`, `adminTrigger_runsOnlyTheCallersTenant`,
`adminTrigger_leavesTheCallersContextIntact`. Count matches list, and both match the diff.

### L-3 — CLOSED

`:360` is now `LOG.info`. Verified against both references independently rather than from round 1's
report: pre-D′ `e83d9550` logged INFO on this exact manual path; `runFor():237` logs INFO. A
five-line comment explains why, and correctly. See R2-L-1 for the one thing the fix leaves open.

---

## Item 4 answered — did the `lenient()` remedy weaken `STRICT_STUBS` elsewhere?

**No.** Three independent confirmations:

1. **Syntactically scoped.** `lenient().when(…)` is a per-stubbing relaxation returning a
   `LenientStubber`; it affects that one stubbing and nothing else. There is no
   `@MockitoSettings(strictness = LENIENT)`, no `withSettings().lenient()` mock, and no change to
   either class's `@MockitoSettings(strictness = STRICT_STUBS)` — the fix diff touches neither
   annotation line.
2. **Only one new site.** `grep -n lenient` on the test class returns exactly two hits: the
   pre-existing `:144` setUp stub (there since before this PR) and the new `:231`. No creep.
3. **Empirically still enforcing.** Under mutant M3′, five *other* tests across the two touched
   classes failed with `UnnecessaryStubbing` — the strictness check firing normally on unrelated
   stubs in the same class and the same run. If the remedy had relaxed the class, those errors would
   not have appeared.

The one thing the lenient stub genuinely gives up is a pin that correct code does *not* read
`CLEAN_UP…` on the short-circuit path. That pin never existed (the stub was previously absent, not
strict), it is not a behavioural property anyone would want to enforce — reading both flags in
either order is semantically identical — and giving it up is what buys the two mutant kills above.
Correct trade.

---

## Verified — what I tried to break at this head and could not

**The whole diff, re-read end to end as if new.** The job class's changes are: two javadoc
corrections (class-level and method-level) replacing the false "activation-flag-free" claim with the
real history, a `@return` tag that now lists "not activated" among the refusal reasons, the restored
gate, and the log level. Every javadoc claim I spot-checked holds — including "this method touches
NO `JobMetrics` call of any kind", which is true of the final `runForCurrentTenant()` body
(`:321-372`, zero `jobMetrics.` references). No drive-by edits, no changes to `runFor()`,
`AdminActionController`, `WmsConstants`, or `StockSummaryExportJob`.

**Placement and lock release, re-checked at the shifted line numbers.** The gate sits inside the
`try` whose `finally` unlocks — after `tryLock`, before `archiveOldMessages()`, the same relative
position `runFor():235-241` uses, same two `WmsConstants` keys, same order, same `||` polarity. The
not-activated `return false` passes through the `finally`, and both new tests'
`verify(advisoryLockService2).unlock(CLEAN_UP_MESSAGES, 1L)` are live rather than vacuous — M3′ and
M6 both prove assertions in these tests actually fire.

**The controller contract.** `AdminActionController:131` returns `ResponseEntity.ok(ran)`, so a
not-activated tenant now gets `200 false` rather than the pre-fix `200 true`. That is the intended
observable consequence of the fix, it is what the PR describes, and it is pinned by
`AdminActionControllerUnitTest:186-192` (the `false` case). No caller in either UI reads a hard-coded
success off this route.

**No silently-drifted test elsewhere.** I enumerated all 10 test classes referencing
`CleanUpOldMessagesJob` and checked which reach `runForCurrentTenant()` un-mocked. The near-duplicate
`CleanUpOldMessagesJobTest` was the one real risk — it constructs the same job and would have been
invisible to a `runForCurrentTenant` grep if it called through a helper — and it does not: all 12 of
its test methods drive `runFor(...)` or the deleted `doCalculation` shape. `AdminActionControllerUnitTest`
mocks the job entirely.

**Sequential Maven only.** All mutation runs and the full-suite run were serialized in the single
review worktree, so no result here is a concurrency false-red.
