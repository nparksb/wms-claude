# PR #288 fact-check — independent claim verification

**Scope:** `wms2-api` PR #288, branch `bugfix/SBDEV-3198-stock-summary-export`, head `680f1f15`, based on `develop`'s tip (`3941fb26`, which already includes PR #286/#287). This lane re-derives every checkable quantitative/completeness claim in the PR's own description. It is NOT a design/correctness review (a sibling lane covers that).

Worktree: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-288-review-b`, detached HEAD at `680f1f15` throughout. No other worktree touched, no `git stash` used.

## Summary table

| # | Claim | Verdict |
|---|---|---|
| 1 | Full suite 6230/0/67, exactly +4 vs 6226 baseline after PR #287 | **PASS** — reproduced exactly on both commits after discarding a contaminated first run |
| 2 | Four new tests (`RunForCurrentTenantLocking`) pin `runForCurrentTenant()`'s lock behavior | **PASS** |
| 3 | Mutation-verified against a hard-coded-wrong-tenant-id mutant, killing the wrong-lock-id test and the int4-overflow test | **PASS** (independently reconstructed the mutant myself) |
| 4 | `TenantSchedule` promoted to top-level, used by two jobs | **PASS** |
| 5 | 8 pre-existing test files touched, 2 of them the SBDEV-3102 duplicate pair | **PASS**, with a phrasing caveat (see detail) |
| 6 | Every `doCalculation(true)`/`(false)` call site for this job repointed at `runFor(spec)`/`runForCurrentTenant()` | **PASS** |
| 7 | `NeverMatcherNullBlindnessArchTest` census: 148 across 37 classes, was 144/36 | **PASS** |
| 8 | Dual-lock mechanism: one-key once per trigger fire, two-key per matching tenant, nested inside the one-key hold | **PASS** (read the code, not just the javadoc) |
| 9 | `JobMetrics` whole-run gauges written once per GROUP fire | **PASS** |
| 10 | `WholeRunSuccessGaugeUnitTest` regression pin confirms safety, with the "single-group fixture only" caveat | **PASS** |
| 11 | `SchedulingConfigurationUnitTest`/`SchedulingReconcileIdempotencyUnitTest` trigger-count assertions correctly narrowed/grown | **PASS**, with one cosmetic staleness noted |
| 12 | `runForCurrentTenant()` preserves `doCalculation(false)`'s behavior exactly except the lock | **PASS** |
| 13 | Two non-scheduler callers (`StockCountRestController`, `AdminActionController`) repointed | **PASS** |

## Detail

### 1. Full suite numbers

**First attempt was invalid — flagging the trap, not just the number.** I started a background `rm -rf target/surefire-reports && mvn -q -o clean test` run, and while it was executing I *also* ran a foreground `mvn -Dtest=StockSummaryExportJobUnitTest test` in the **same worktree** to verify claim #3's mutation-testing claim (see below), including a temporary source-file mutation. The two concurrent Maven processes shared `target/`, and the resulting surefire-report sum came back **6230/3/0/67** — 3 failures, all in `StockSummaryExportJobUnitTest$RunForCurrentTenantLocking`, i.e. contaminated by my own concurrent mutant, not a real defect. This matches a known trap from this session's own memory ("Concurrent Maven in one worktree = false reds" — 238 errors racing, 0 alone; one worktree per build). Confirmed the worktree was clean (`git status --short` empty, `git diff --stat` empty) before starting a second, isolated run.

**Second attempt, run alone with nothing else touching the worktree** (`rm -rf target/surefire-reports && mvn -q -o clean test`, summed across every `target/surefire-reports/*.txt`):

- **`680f1f15` (PR head):** 1676 report files → **Tests run: 6230, Failures: 0, Errors: 0, Skipped: 67.** Exact match to the PR body.
- **`3941fb26` (develop tip, PR #287's merge commit — checked out temporarily in this same worktree, restored to `680f1f15` afterward and confirmed via `git rev-parse HEAD`):** 1675 report files → **Tests run: 6226, Failures: 0, Errors: 0, Skipped: 67.** Exact match to the PR body's baseline.
- Delta: `6230 − 6226 = 4`, exactly matching "+4 (the new `RunForCurrentTenantLocking` tests)" — and independently, `RunForCurrentTenantLocking` is confirmed above (§2) to contain exactly 4 `@Test` methods, with no `@ParameterizedTest`/`@RepeatedTest` expansion in that class, so the source-level count and the Surefire-measured delta agree by two independent methods.

**PASS — all three numbers (6230/0/67 head, 6226/0/67 baseline, +4 delta) reproduced exactly**, via a from-scratch `mvn clean test` run on both commits in the same isolated worktree, not merely trusted from the PR body.

### 2. Four new tests — `RunForCurrentTenantLocking`

`src/test/java/net/aim_ai/wms/unit/schedulejob/StockSummaryExportJobUnitTest.java:345-347` — new `@Nested @DisplayName("SBDEV-3198 step 4 — runForCurrentTenant()'s two-key lock widening") class RunForCurrentTenantLocking`, confirmed new (not a rename) via `git diff develop..HEAD` on the file — the whole class plus its imports (`TenantContext`, `TenantProfile`, `Tenant`, `TenantDbConfiguration`) are additions. Exactly 4 `@Test` methods inside it:

1. `refusesWhenTenantCannotBeResolved` — tenant-not-resolved refusal
2. `refusesWhenIdOverflowsInt4` — int4-overflow refusal
3. `skipsWhenTwoKeyLockIsBusy` — lock-busy skip
4. `locksOnTheCallersOwnTenantId` — locks on the caller's own id, not a hard-coded one

All four branch names match the PR body's own description of the four behaviors. **PASS.**

### 3. Mutation-verification claim

Rather than trust the PR body's account of a prior pass, I independently constructed the same mutant: in `StockSummaryExportJob.java`, changed `long tenantId = config.get().getId();` to `long tenantId = 999999L; // MUTANT: hard-coded wrong tenant id` inside `runForCurrentTenant()`, then ran `mvn -Dtest=StockSummaryExportJobUnitTest test`.

Result: **3 failures**, not 2 — my mutant is cruder than whatever the original pass used, so it also killed `skipsWhenTwoKeyLockIsBusy` (that test stubs `tryLock(..., 1L)` to return `false`; with the id hard-coded to `999999L` the stub for `1L` never matches and Mockito's unstubbed default returns `false` for a `boolean` — which happens to still take the "busy" branch, but the constant-id `999999L` on `LOG.debug` calls doesn't match either). The two the PR body specifically named were killed with **attributable Mockito diagnostics**:

```
StockSummaryExportJobUnitTest$RunForCurrentTenantLocking.locksOnTheCallersOwnTenantId:413
Argument(s) are different! Wanted: advisoryLockService.tryLock(100004L, 42L); Actual: tryLock(100004L, 999999L)

StockSummaryExportJobUnitTest$RunForCurrentTenantLocking.refusesWhenIdOverflowsInt4:377
warehouseStockReportService.streamStockCount(<any>) — Never wanted here. But invoked here.
```

Both failure messages name the exact wrong value (`999999L` where `42L` was expected), which is exactly "attributable messages." Reverted the mutant immediately after (`git diff --stat` confirmed clean before continuing). **PASS** — confirmed independently, and the claim actually understates the mutant's kill radius (3 tests, not 2, though the PR only claimed 2 by name and both of those are correctly named).

### 4. `TenantSchedule` promoted to top-level

`src/main/java/net/aim_ai/wms/schedulejob/TenantSchedule.java` is a genuinely new top-level file (`git diff --name-status` shows `A`), `public record TenantSchedule(TriggerSpec spec, ZoneId resolvedZone)`. Grepped for `StaleClubBatchCleanupJob.TenantSchedule` (the old nested-class reference form) across `src/` — **zero hits**. Confirmed referenced from both `StaleClubBatchCleanupJob.java:100,112,158` and `StockSummaryExportJob.java:147,159,208`, plus three test files. **PASS.**

### 5. "8 pre-existing test files touched, 2 of them a known SBDEV-3102 duplicate pair"

`git diff develop..HEAD --name-status` shows **12** test files touched total (all `M`, none `A`):
`SchedulingConfigurationUnitTest`, `SchedulingReconcileIdempotencyUnitTest`, `StaleClubBatchCleanupJobDeriveSpecUnitTest`, `NeverMatcherNullBlindnessArchTest`, `AdminActionControllerUnitTest`, `StockCountRestControllerUnitTest`, `StockSummaryExportJobBulkInsertTest`, `StockSummaryExportJobMetricsUnitTest`, `StockSummaryExportJobOmsDecouplingTest`, `StockSummaryExportJobTest`, `StockSummaryExportJobUnitTest`, `WholeRunSuccessGaugeUnitTest`.

Read literally, "8" undercounts by 4. But the PR body's paragraph structure names `SchedulingConfigurationUnitTest`, `SchedulingReconcileIdempotencyUnitTest`, and `NeverMatcherNullBlindnessArchTest` **individually, in the two sentences immediately following** the "8 pre-existing test files" sentence — a natural reading is that "8" is the count of files *not already called out by name in the same paragraph*. Subtracting those 3 from the 12 leaves exactly **8**:
`StaleClubBatchCleanupJobDeriveSpecUnitTest`, `AdminActionControllerUnitTest`, `StockCountRestControllerUnitTest`, `StockSummaryExportJobBulkInsertTest`, `StockSummaryExportJobMetricsUnitTest`, `StockSummaryExportJobOmsDecouplingTest`, `StockSummaryExportJobTest`, `StockSummaryExportJobUnitTest`.

All 8 are genuinely pre-existing (`M`, not `A`), and both halves of the SBDEV-3102 duplicate pair (`StockSummaryExportJobTest.java` / `StockSummaryExportJobUnitTest.java`) are present in that list. **Verdict: PASS under the paragraph-scoped reading** — flagging the ambiguity since the plain/literal reading of "8 pre-existing test files touched" (unscoped, against the whole diff) would read as **FAIL** (actual: 12). This is exactly the kind of completeness-word slip this repo's history flags as the most common break, so I'm not silently picking the charitable reading — the number resolves exactly one way and not the other, and a reader skimming just that sentence without noticing the following two name three more files would reasonably conclude "8" undercounts.

### 6. `doCalculation` call-site repointing

`git grep -n "doCalculation"` across `src/` shows zero references inside `StockSummaryExportJob.java`'s production code (5 remaining hits there are all javadoc prose describing the *removal*). The two production callers are exact 1-line swaps:
- `AdminActionController.java:118`: `stockSummaryExportJob.doCalculation(false)` → `stockSummaryExportJob.runForCurrentTenant()`
- `StockCountRestController.java:111`: `() -> stockSummaryExportJob.doCalculation(false)` → `stockSummaryExportJob::runForCurrentTenant`

The scheduler call site (`SchedulingConfiguration.java:833`) now calls `stockSummaryExportJob.runFor(spec)`. Remaining `doCalculation` call sites in the codebase belong to the 4 still-unconverted jobs (`CleanUpOldMessagesJob`, `OrderReleaseJob`, `ReleaseExpiredPickingOrdersFromUserJob`, `ReplenishOrderJob`), correctly out of scope for this PR. **PASS.**

### 7. `NeverMatcherNullBlindnessArchTest` census: 148/37, was 144/36

`git diff develop..HEAD` on this file shows **exactly one** entry added to `PRIMITIVE_MATCHER_INVENTORY`: `"StockSummaryExportJobUnitTest:4",`, and the doc-comment updated from "144 across 36 classes" to "148 across 37 classes." Independently counted the current `PRIMITIVE_MATCHER_INVENTORY` list: **37 entries**, values summing to **148**. Confirmed the two `never().tryLock(anyLong(), anyLong())` sites in `StockSummaryExportJobUnitTest.java` (lines 359, 378 — inside `refusesWhenTenantCannotBeResolved` and `refusesWhenIdOverflowsInt4`, "one per test" as claimed). **PASS.**

### 8. Dual-lock mechanism

Read `StockSummaryExportJob.runFor(TriggerSpec spec)` in full (not just its javadoc):
- **One-key lock**: `advisoryLockService.tryLock(AdvisoryLockService.JobLockId.STOCK_SUMMARY_EXPORT)` at the very top, before the tenant loop; released in the method's outer `finally` (no tenant id argument) — taken/released exactly once per `runFor` call (= once per trigger fire).
- **Two-key lock**: `advisoryLockService.tryLock(AdvisoryLockService.JobLockId.STOCK_SUMMARY_EXPORT, tenantId)` inside the per-tenant loop body, only for tenants whose own derived spec matches the fired `spec`; released in an inner `finally` scoped to that tenant's iteration — nested inside the outer one-key hold, exactly as the javadoc states.

**PASS** — verified against the actual control flow, not the comment describing it.

### 9. `JobMetrics` per-group writes

`jobMetrics.markLastRun()`, `.recordDuration(...)`, and `.skippedLockBusy()` (early-return branch) all live in `runFor`'s outer scope — called once per invocation, i.e. once per group fire, never inside the per-tenant loop. `markLastSuccess()` is called either on the empty-active-tenants branch or once after the loop (gated on `!anyFailure`) — also once per `runFor` call. **PASS**, matches "written once per GROUP fire."

### 10. `WholeRunSuccessGaugeUnitTest` regression pin

`git diff develop..HEAD` on this file shows the `StockSummaryExport` nested class's 4 tests repointed from `job().doCalculation(true)` to `job().runFor(SPEC)`, where `SPEC` is a single shared `TriggerSpec` both fixture tenants are stubbed to derive — i.e. exactly one group in this fixture. The class's own javadoc was rewritten with an explicit "⚠ UPDATED 2026-09-03" paragraph stating verbatim what the PR body claims: safe here specifically because this fixture's two tenants collapse into one group, **not** because per-group writes are safe in general — and names the multi-group case as the still-open "new, tagged meter" gap. **PASS**, word-for-word match between the PR body's claim and the shipped javadoc.

### 11. `SchedulingConfigurationUnitTest`/`SchedulingReconcileIdempotencyUnitTest` trigger-count updates

`EXPECTED_TRIGGER_COUNT = 6` in both files (4 single-trigger jobs + 1 single-zone trigger each for the two now-grouped jobs). Two-zone tests correctly bumped from `EXPECTED_TRIGGER_COUNT + 1` to `EXPECTED_TRIGGER_COUNT + 2` (e.g. `differentZonesMeanTwoGroups`, `callerContextIsRestored`). "Four single-trigger jobs" phrasing used consistently through both diffed files where trigger-scope logic changed.

**One cosmetic staleness found and worth flagging**: `SchedulingConfigurationUnitTest.java:1155`'s `@DisplayName` still reads *"...so the **five** single-trigger jobs still read under the probe tenant"* — not narrowed to "four" — even though the test body immediately below it (lines 1167-1172) was correctly updated to exclude **both** grouped jobs' hour-sysprop reads from the "single-trigger" bucket. This is a display-string-only miss (the assertion logic is correct), and the PR body's own claim only says "**several**... invariants correctly narrow to 4" (not "all" or "every"), so this doesn't contradict the claim as worded — but it's exactly the kind of stale-count leftover worth naming. **PASS on the claim as worded; one un-narrowed DisplayName noted as a minor finding.**

### 12. `runForCurrentTenant()` preserves `doCalculation(false)`'s behavior exactly except the lock

Read the method body (`StockSummaryExportJob.java:288-320`): resolves `TenantContext.getCurrentTenant()`, refuses if null; looks up `tenantDbConfigurationRepository.findByTenantNameAndWarehouse(...)`, refuses if absent; guards `Math.toIntExact` and refuses on overflow; takes the two-key `(100004, tenantId)` lock (the deliberate change) instead of the old one-key form; calls `exportStockSummary(null)` directly — **no** activation-flag sysprop check, **no** per-tenant `jobMetrics` calls, no tenant iteration. This matches "no activation-flag check, no per-tenant JobMetrics, current TenantContext only" from the javadoc precisely. **PASS.**

### 13. Two non-scheduler callers repointed

Confirmed via diff in section 6 above — both `StockCountRestController.triggerSchedule()` and `AdminActionController.triggerUpdateStock()` now call `runForCurrentTenant()`. **PASS.**

## Bottom line

**13 claims checked. 13 PASS, 0 FAIL, 0 UNVERIFIABLE** — with one caveat worth a human's attention (#5, the "8 pre-existing test files" count only resolves exactly under a paragraph-scoped reading — the plain/unscoped reading of that single sentence against the whole diff would read as 12, not 8) and one cosmetic miss noted but not counted against the claim as worded (#11, one un-narrowed `@DisplayName` string still says "five single-trigger jobs").

The headline suite numbers reproduced **exactly**: PR head `680f1f15` = 6230/0/67, develop baseline `3941fb26` (PR #287's merge into develop) = 6226/0/67, delta = exactly +4, matching the 4 new `RunForCurrentTenantLocking` tests both by direct Surefire measurement and by independent source-level count. Both suite runs were from-scratch (`clean test`, wiped `target/surefire-reports`), run alone in the isolated worktree with nothing else concurrently touching it.

**One real process trap hit and corrected in this pass, worth flagging to the team**: a first attempt at the full-suite run was contaminated because I ran a second, foreground Maven process (for the mutation-testing check) concurrently with the background full-suite run, in the *same* worktree — both processes share `target/`, and the result was 3 phantom failures that had nothing to do with the PR. Discarded that run, confirmed the worktree was clean, and reran alone. This matches this session's own prior "concurrent Maven in one worktree = false reds" lesson — restating it here since it's easy to trip on even when you already know about it.

The mutation-verification claim (#3) was independently reconstructed, not just trusted: I built the same hard-coded-wrong-tenant-id mutant myself, ran it, and confirmed it kills both named tests (`refusesWhenIdOverflowsInt4`, `locksOnTheCallersOwnTenantId`) with attributable Mockito diagnostics naming the exact wrong value — and reverted it immediately, confirming a clean `git diff` before continuing.
