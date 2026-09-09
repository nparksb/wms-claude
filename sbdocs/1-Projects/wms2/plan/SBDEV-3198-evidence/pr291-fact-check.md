---
name: pr291-fact-check
description: Independent fact-check of pr291-review-code.md's claims against wms2-api PR #291 (SBDEV-3198 step 5 part 1/4, CleanUpOldMessagesJob → D′) at commit 55ec08e1
lane: fact-check (verifies the review lane's claims — line citations, mutant results, structural-diff and census claims — not a fresh design review)
reviewed: 2026-09-03
base: f440b534 (develop tip, post-#288 merge)
head: 55ec08e1
worktree: /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-291-review-code
source reviewed: sbdocs/1-Projects/wms2/plan/SBDEV-3198-evidence/pr291-review-code.md
---

# PR #291 review — fact-check

## Verdict

**The review holds up. Every specific, checkable claim I independently re-derived matched exactly** —
line numbers, test names, mutant outcomes, the structural diff, the migration SQL, config values, and
the PR body quote it disputes in L-3. I found no false claim and no overstated evidence. One small
citation-precision nit in L-3 (below), not worth a severity of its own.

## Method

Worked entirely in the reviewer's own worktree (`SBDEV-3198-291-review-code`, clean at `55ec08e1`
throughout — confirmed `git status --porcelain` empty before and after). Did not read the review's
conclusions and accept them; re-derived each checkable claim from the source files, then compared.
`mvn`/`java` are not on this shell's default `PATH` — resolved via
`~/.sdkman/candidates/{maven,java}/current/bin`.

## Verified — every claim checked, with independent method

| Claim | My independent check | Result |
|---|---|---|
| Full suite reproduces 6250/0/0/67 BUILD SUCCESS at `55ec08e1` | Ran `mvn -o clean test` myself, summed all `target/surefire-reports/*.txt` by script (not trusting the console tail) | **Confirmed exactly**: 6250 run, 0 failures, 0 errors, 67 skipped |
| Mutant H — add `markLastRun()`+`recordDuration()` into `runForCurrentTenant()`'s `try` block SURVIVES the full suite | Applied the identical 2-line edit myself, ran the **full** suite (not the claimed subset), reverted via `git checkout --` afterward | **Confirmed exactly**: 6250/0/0/67, BUILD SUCCESS — the mutant survives, corroborating M-1, the review's central "fix before merge" finding |
| Line numbers `:180`,`:188`,`:193`,`:209`,`:212` (dual-lock sites), `:171-172` (`Math.toIntExact`+`LOG.trace`), `:214` (outer catch), `:274/:282/:290/:295/:302` (five refusal returns) | `grep -n` against the exact patterns in `CleanUpOldMessagesJob.java` | **All match exactly**, no off-by-one anywhere |
| `runForCurrentTenant()`'s "gauges deliberately NOT recorded" javadoc claim (`:252-257`) is unpinned — no `markLastRun`/`recordDuration` call in that method, and `doesNotTouchTheWholeRunGauges` exists only in `StockSummaryExportJobUnitTest`, not `CleanUpOldMessagesJobUnitTest` | `sed`/`grep` the method body; `grep -rn "doesNotTouchTheWholeRunGauges" src/test` | **Confirmed** — zero hits for that assertion name in the CleanUpOldMessages test file |
| `CleanUpOldMessagesJobUnitTest.RunForCurrentTenantLocking` has 5 of `StockSummaryExportJobUnitTest.RunForCurrentTenantLocking`'s 6 tests, missing exactly `doesNotTouchTheWholeRunGauges` | Enumerated both nested classes' `@Test` methods by exact class boundary (`grep -n` around the `@Nested class` markers) | **Confirmed**: StockSummaryExportJob's has 6 (`refusesWhenTenantCannotBeResolved`, `refusesWhenIdOverflowsInt4`, `skipsWhenTwoKeyLockIsBusy`, `returnsFalseAndStillUnlocksWhenExportThrows`, `doesNotTouchTheWholeRunGauges`, `locksOnTheCallersOwnTenantId`); CleanUpOldMessages' has the same 5 minus the gauge test |
| `configureCleanUpOldMessagesGroups` (`:697-786`) is byte-identical to `configureStockSummaryExportGroups` (`:844-933`) except the log label | Extracted both 90-line method bodies verbatim, substituted job identifiers with `sed`, `diff -u` the normalized text myself (not re-reading the review's diff) | **Confirmed**: single hunk, the log-label string only (`"Clean Up Old Messages"` vs `"Stock Summary Export"`) |
| `configureAllTasks` registers 3 grouped jobs before 3 `onlyIfMissing` singles (`:637-648` region) | Read `configureAllTasks(TaskScheduler, String, boolean)` directly | **Confirmed** — StaleClub, StockSummaryExport, CleanUpOldMessages grouped calls, then orderRelease/replenish/releaseExpiredPickingOrdersFromUser via `onlyIfMissing` |
| Trigger-count math: `EXPECTED_TRIGGER_COUNT = 6`; `differentZonesMeanTwoGroups` → `+3`; `noScheduleTenantIsNamed` → `+2` | `grep -n` the constant and the two assertions in `SchedulingConfigurationUnitTest.java` | **Confirmed** both deltas exactly as cited |
| `V2.2.20` and `V2.2.00` — `message_archived` has no PK, 18 plain columns, nullable `id bigint`; `V2.2.20`'s comment already documents it as tolerating duplicates | Read both migration files directly, counted columns | **Confirmed**: exactly 18 columns, `id bigint` with no constraint of any kind; `V2.2.20:353-360` text matches the review's paraphrase closely, including "can ALREADY hold duplicate ids, silently" |
| `MessageRepository.archiveMessages` is a bare `INSERT INTO message_archived SELECT * FROM message where created < :refDate`, no de-dup guard | Read the `@Query` annotation directly | **Confirmed verbatim** |
| `CleanUpOldMessageJobService`: `MAX_SLEEP_MS = 5_000L` (`:36`), `do { … sleeper.sleep(sleepMs) … } while (deletedCount >= batchSize)` (`:92-104`) | Read the method directly | **Confirmed**, line numbers exact |
| `landlord.datasource.maximum-pool-size=2` unchanged (`:66`); `connection-timeout=20000` (`:70`) | `grep -n` `application.properties` | **Confirmed** both |
| `AdvisoryLockService.tryLock` catches `SQLException` and returns `false` at `:103-105` (one-key) and `:205-207` (two-key) | `grep -n "catch (SQLException\|return false"` | **Confirmed** exact line ranges |
| 12 `tryLock(AdvisoryLockService.JobLockId.*)` call sites in `src/main`, across 8 jobs, exactly 2 one-key/two-key same-thread pairs (`CleanUpOldMessagesJob:180+188`, `StockSummaryExportJob:266+274`) | `grep -rn` the exact pattern, counted by hand | **Confirmed**: 12 sites, 8 distinct job classes, exactly the two named pairs |
| Only 2 production callers of `CleanUpOldMessagesJob` — `SchedulingConfiguration` and `AdminActionController:131` | `grep -rn "cleanUpOldMessagesJob\.\|CleanUpOldMessagesJob" src/main`, excluding the class's own file | **Confirmed** — the only other hit is a comment in a migration file, not a caller |
| `AdminActionController`: `triggerArchiveMessages` (`:131`) assigns+returns the real boolean; `triggerOrderReplenish`'s `ok(true)` at `:112` and `triggerReleaseExpiredPickingOrdersFromUser`'s at `:176` are still hardcoded and correctly out of scope | `grep -n "ResponseEntity.ok(true)\|boolean ran = "` | **Confirmed**, exact line numbers |
| `NeverMatcher` census: PR body claims "150→154 across 38→39"; source supports "148→154 across 37→39" | Fetched the actual PR #291 body via `gh pr view 291 --json body`; independently enumerated `PRIMITIVE_MATCHER_INVENTORY` (39 entries, sums to 154) and re-summed with the two new classes (`AdminTriggerTenantScopeUnitTest`, `CleanUpOldMessagesJobUnitTest`) removed (37 entries, sums to 148) | **Confirmed** — PR body literally says "150→154 across 38→39 classes"; direct enumeration of the list (not just the javadoc prose) gives 148/37 pre-step-5, matching the review's corrected figures. Also independently confirmed the 2-and-4-matcher counts via `grep -n "never()"` in both new test classes |
| Round-2 M-3 citation from `pr288-review2-code.md:466-468` and N-5 citation from same file | `sed`/`grep` the cited lines in the actual pr288 file | **Confirmed near-verbatim** on both |
| `WholeRunSuccessGaugeUnitTest`'s removal of an "unnecessary under STRICT_STUBS" `tryLock(CLEAN_UP_MESSAGES)` stub | `git diff f440b534 55ec08e1 -- .../WholeRunSuccessGaugeUnitTest.java`, found the actual removed line + inline comment | **Confirmed**, and the PR's own added comment states the exact reasoning the review paraphrases |
| `CleanUpOldMessagesJobMetricsUnitTest`'s duration assertion changed `isZero()` → `isEqualTo(1)`, correctly forced by the H-1 shape | Same `git diff` technique on this file | **Confirmed**, with the PR's own comment matching the review's explanation nearly word-for-word |
| L-4: `skippedLockBusy()` at `:184` is inside the per-tenant loop; `markLastSuccess()` at `:233`; the metrics-fixture test uses a **one-tenant** fixture and asserts `1.0` | Read the source and `tryLockBusy_incrementsSkippedLockBusyCounter` directly | **Confirmed** — fixture stubs `findByActiveTrue()` to a single-element list, asserts `.isEqualTo(1.0)` |
| L-5: pre-PR `tenantSample = jobMetrics.startTenantTimer()` was the loop's first statement, ran unconditionally, at `f440b534:...:93` | `git show f440b534:.../CleanUpOldMessagesJob.java` | **Confirmed** exact line and content |
| `busyOneKeySkipsOnlyThatTenant` and the other 3 `DualLockPerTenantScoping` tests exist as the review's "Verified" section claims | `grep -n` the nested class and its 4 `@Test` methods in `CleanUpOldMessagesJobTest.java` | **Confirmed** — 4 tests: `busyOneKeySkipsOnlyThatTenant`, `throwingTenantReleasesBothLocks`, `twoTenantGroupReleasesEachLockTwice`, `runForSkipsInt4OverflowingTenantWithoutLocking` |
| `deriveSpecForCurrentTenant()`'s own `try` (`:156-163`) sets only `anyReadFailure`; `ArithmeticException` catch (`:171-176`) does not re-set it | Read the source directly | **Confirmed**, no `anyReadFailure = true` in the int4-overflow catch block |

## Minor nit — not a defect, a citation-precision note

**L-3's phrasing implies the "148 across 37" figures are printed text at `NeverMatcherNullBlindnessArchTest.java:384-390`.** They are not — those lines are prose describing the *deltas* added by three tickets (StaleClub, StockSummaryExport, step-5's two classes), and the "148"/"37" numbers are a derivation from that prose, not a literal quote. The authoritative source for both figures is the `PRIMITIVE_MATCHER_INVENTORY` list itself (starts a few lines below, at `:401`), which I enumerated directly and got the same 148/37 and 154/39 totals. The review's arithmetic and conclusion are correct; the citation form slightly overstates how literally lines 384-390 say what's quoted. Not worth its own severity line — folding it into this note per the citation-form discipline in `wms-triage`.

## What I did not re-verify

- The other seven hand mutants (A-G, I, J) — I trust these less than mutant H (which I reproduced
  myself against the full suite) only because I did not have time to reproduce all nine; I did verify
  every line number and test-existence claim underlying them (the `tryLock`/`unlock` sites, the five
  `return false` sites, `AdminActionControllerUnitTest`'s existence, `:184`'s `skippedLockBusy()`
  call), which is the part most likely to be wrong in a fabricated claim. Nothing in that underlying
  evidence contradicts the claimed KILLED outcomes.
- Whether the running landlord `maximumPoolSize` was ever actually read from a live environment (M-2) —
  this is an operator/infra question, not a code fact, and outside what a worktree-scoped fact-check
  can confirm either way. The review's own honesty about this (states it could not connect to any DB/
  actuator MCP server) is itself consistent with what I observed: all 12 DB MCP servers in this session
  also failed with `CONNECT_TIMEOUT`.

## Bottom line

I found zero inaccuracies in the review's citations, zero unsupported "the tests prove X" claims, and
independently reproduced its two most load-bearing measurements (the full-suite baseline and mutant H).
The review's verdict — **FIX BEFORE MERGE, one test (M-1) plus one overdue decision (M-2)** — is
well-supported by the evidence as it stands in this worktree at `55ec08e1`.
