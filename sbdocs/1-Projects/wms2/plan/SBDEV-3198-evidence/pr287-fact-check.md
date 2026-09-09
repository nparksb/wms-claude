# PR #287 fact-check — independent claim verification

**Scope:** `wms2-api` PR #287, branch `bugfix/SBDEV-3198-dprime-followup`, head `adb141b1`, based on `7b7db3b6` (develop tip at review time). This lane re-derives every checkable quantitative/completeness claim in the PR's own description. It is NOT a design/correctness review (a sibling lane covers that).

Worktree: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-287-review-b`. Restored to `adb141b1` after the baseline detour; confirmed via `git rev-parse HEAD`.

## Summary table

| # | Claim | Verdict |
|---|---|---|
| 1 | Full suite 6225/0/67, freshly measured | **PASS** |
| 2 | develop baseline (derived) 6218/0/67 | **PASS** (directly re-measured, not just derived) |
| 3 | Delta exactly +7, matches 7 new `@Test` methods | **PASS** |
| 4 | `6216 (a35cab5a) + 2 (#285) + 7 (this PR) = 6225` reconciliation | **PASS** |
| 5 | H-1 fix: separate ThreadLocal slots, nesting now safe | **PASS** (code) |
| 6 | H-1 mutation-verification claim (1 new + 2 pre-existing tests killed) | **UNVERIFIED-IN-THIS-PASS** (not reproduced; see below) |
| 7 | M-2: three new tests for previously-unpinned branches | **PASS** |
| 8 | M-3: `TenantSchedule` record carries pre-collapse resolved zone | **PASS** |
| 9 | M-4: no-context guard moved to top of method | **PASS** |
| 10 | M-5: stale cost comment restated | **PASS** |
| 11 | M-6: "five raw literals replaced" | **FAIL** — actual count is 11, not 5 |
| 12 | M-7: success log gated on registry ground truth | **PASS** |
| 13 | L-1 through L-5: each described fix present | **PASS** (all 5) |
| 14 | L-6/L-7/L-8 deliberately deferred (no silent regression) | **PASS** |
| 15 | L-9 informational, no action needed | **PASS** |
| 16 | "1 High, 6 Medium, 9 Low" review-count claim | **PASS** |

## Detail

### 1–4. Suite numbers and reconciliation arithmetic

Ran `rm -rf target/surefire-reports && mvn -q -o clean test` twice in the isolated worktree, once at each commit (restoring to `adb141b1` afterward, confirmed via `git rev-parse HEAD`):

- **`adb141b1` (PR head):** summed `target/surefire-reports/*.txt` (1675 report files) → **Tests run: 6225, Failures: 0, Errors: 0, Skipped: 67.** Matches the PR body exactly.
- **`7b7db3b6` (develop tip, checked out temporarily in this worktree only):** summed `target/surefire-reports/*.txt` (1672 report files) → **Tests run: 6218, Failures: 0, Errors: 0, Skipped: 67.** Matches the PR's "derived" baseline exactly — and this is a **direct measurement**, not a derivation, so it independently confirms the PR's arithmetic rather than merely trusting it.
- Delta: 6225 − 6218 = **+7**, matching the `@Test` count delta computed independently (see below).
- Separately verified the `a35cab5a + #285 + this PR` reconciliation chain: `a35cab5a` is **not an ancestor** of `7b7db3b6`/`adb141b1` (confirmed via `git merge-base --is-ancestor a35cab5a 7b7db3b6` → false) — it is a sibling commit from PR #286's original branch before squash-merge onto develop, exactly as the PR body describes. Diffing `e9e03f0f` (pre-#285) → `6b10cf94` (#285, "SBDEV-3205 follow-up") shows `MobilePickingServiceUnitTest.java` gained exactly **2** `@Test` methods (103→105); the companion `ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest.java` changed (delta 0 `@Test` count) but is an `*IntegrationTest` file excluded from the `mvn test` (surefire) lane per this repo's own convention, so it doesn't affect the count either way. `6216 (a35cab5a) + 2 (#285) + 7 (this PR) = 6225` — reconciles exactly, and is now doubly confirmed by the direct 6218 baseline measurement (6216 + 2 = 6218).

**Trap check:** used `clean test` (not bare `test`) and wiped `target/surefire-reports` before each run, so no stale-report inflation. Did not use `-Dtest='!*IT'` or any test-selection flag — ran the full default surefire lane both times.

### @Test count per changed test file (old vs new, `7b7db3b6` → `adb141b1`)

| File | old | new | Δ |
|---|---|---|---|
| `SchedulingConfigurationUnitTest.java` | 42 | 42 | 0 |
| `SchedulingReconcileIdempotencyUnitTest.java` | 21 | 21 | 0 |
| `StaleClubBatchCleanupJobDeriveSpecUnitTest.java` (new file) | 0 | 2 | +2 |
| `TriggerSpecUnitTest.java` | 4 | 5 | +1 |
| `StaleClubBatchCleanupJobUnitTest.java` (unit/schedulejob) | 14 | 17 | +3 |
| `AdvisoryLockServicePerTenantLockUnitTest.java` | 10 | 11 | +1 |
| **Total** | | | **+7** |

No `@ParameterizedTest`/`@RepeatedTest` present in any of the diffed hunks — plain `@Test`, so the grep count equals Surefire's per-file test count with no expansion factor to account for.

### 5. H-1 — separate ThreadLocal slots

Confirmed in `src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java`: a second field `lockedTenantConnection` was added; the two-key `tryLock`/`unlock` methods now read/write it instead of the shared `lockedConnection`. A new nesting test (`AdvisoryLockServicePerTenantLockUnitTest.DualLockNesting.oneKeyAndTwoKeyNestWithoutOverwritingEachOther`) asserts both connections stay open and are released independently. Matches the claim.

### 6. H-1 mutation-verification claim — UNVERIFIED-IN-THIS-PASS

The PR body itself frames this as a prior pass's finding ("mutation-verified against the pre-fix single-slot behavior"), not something re-derivable against this commit without reconstructing the mutant by hand. Per the task instructions this was optional and time-permitting; I did not attempt it in this pass, so this claim is **UNVERIFIED-IN-THIS-PASS**, not FAIL. The described test (`oneKeyAndTwoKeyNestWithoutOverwritingEachOther`) does exist and does assert connection-identity/close-call behavior that would plausibly kill a single-slot mutant, but I did not construct the pre-fix mutant and run it.

### 7–10, 12. M-2 through M-7 (except M-6)

- **M-2:** `StaleClubBatchCleanupJobUnitTest.java` gained a `@Nested UnpinnedBranchesFromReview` class with exactly 3 `@Test`s covering the malformed-row branch, the int4-overflow branch, and the unreadable-tenant-vs-empty-group distinction. Grepped the corresponding log strings (`"malformed tenant_db_configuration row"`, `"found no MATCHING readable tenant"`, `"matched no active tenant"`) in `StaleClubBatchCleanupJob.java` — all three pre-exist unchanged in `7b7db3b6`, confirming these are new **tests** against pre-existing branches, not new code paths. Matches the claim precisely.
- **M-3:** New `StaleClubBatchCleanupJob.TenantSchedule(TriggerSpec spec, ZoneId resolvedZone)` record; `deriveSpecForCurrentTenant()` now returns it; `SchedulingConfiguration`'s UTC-fallback WARN checks `schedule.resolvedZone().getId()` instead of `spec.zoneId()`. New test `StaleClubBatchCleanupJobDeriveSpecUnitTest.resolvedZoneSurvivesTheZoneInvariantCollapse` pins exactly this. Matches.
- **M-4:** The `TenantContext.getCurrentTenant() == null` guard now runs before the two `syspropService.getSysvalue(...)` calls (previously after). New test `noContextGuardFiresBeforeAnySyspropRead` asserts `verify(syspropService, never()).getSysvalue(any())`. Matches.
- **M-5:** The javadoc paragraph on `SchedulingConfiguration`'s reconcile method was rewritten from describing "the first-iterated tenant's pool" to describing a touch of "as many tenants' pools as are cached (UAT: 4)" — a real prose restatement, not a code change (M-5 was a stale-comment finding). Matches.
- **M-7:** The `LOG.info("... group {} covers tenant(s) {}", ...)` call is now gated behind `if (registrations.containsKey(registryKey))`, with a new `LOG.warn(...)` else-branch. Matches the claim that this closes the `future == null` silent-no-op gap.

### 11. M-6 — **FAIL**, quantitative claim does not match the diff

PR body: *"five raw `"staleClubBatchCleanup"` literals replaced with `StaleClubBatchCleanupJob.JOB_NAME`."*

Counted every line removed from `SchedulingConfiguration.java` between `7b7db3b6` and `adb141b1` that contained the literal text `staleClubBatchCleanup` as a string (excluding the one line that uses it only as part of the `staleClubBatchCleanupJob` identifier, which is unrelated):

```
git diff 7b7db3b6 adb141b1 -- src/main/java/net/aim_ai/wms/schedulejob/SchedulingConfiguration.java \
  | grep -E '^-.*staleClubBatchCleanup'
```

Result: **11 distinct lines**, all replaced with a `StaleClubBatchCleanupJob.JOB_NAME` reference in the corresponding `+` line:
1. `CONFIGURED_JOB_NAMES` list entry (`:70`)
2. `noSchedule` error log arg (`:891`)
3. `unreadable` warn log arg (`:895`)
4. `utcFallbacks` warn log arg (`:901`)
5. `registryKey` concatenation prefix, `"staleClubBatchCleanup@"` (`:906`)
6. `register(registryKey, "staleClubBatchCleanup", ...)` call arg (`:916`)
7. `LOG.info("staleClubBatchCleanup group {} covers tenant(s) {}", ...)` — literal embedded in message text, restructured to `"{} group {} covers tenant(s) {}"` + `JOB_NAME` arg (`:923`)
8. `LOG.error("Failed to configure staleClubBatchCleanup group {} for tenant(s) {}", ...)` — same pattern (`:925`)
9. `registeredJobNames().contains("staleClubBatchCleanup")` (`:933`)
10. `LOG.error("staleClubBatchCleanup cron schedule not configured...")` — embedded, restructured (`:935`)
11. `LOG.error("Failed to configure staleClubBatchCleanup groups", e)` — embedded, restructured (`:947`)

Cross-checked against the **original review's own finding text** (`sbdocs/1-Projects/wms2/plan/SBDEV-3198-evidence/step3-review-code.md:192`), which itself is titled *"raw literal at **five** sites"* and enumerates `:891, :895, :901, :916, :933` as "five sites", **plus** the `CONFIGURED_JOB_NAMES` entry at `:70` named separately ("plus the `CONFIGURED_JOB_NAMES` entry"). So even the *review's own* "five" undercounts by at least one (the `:70` entry), and the PR's actual fix went further still — it also cleaned up three more embedded-literal log messages (`:906`, `:923`/`:925` pair, `:935`, `:947`) that neither the review nor the PR body ever named individually.

**Verdict: the PR body's "five" is inaccurate against its own diff — the real count is 11 sites** (or 6, using the narrower "standalone-argument literal" definition that also includes `:70`). This does not affect functional correctness (all sites *were* fixed, which is a strictly better outcome than the review asked for) — it's a pure quantitative-claim miss, exactly the pattern this repo's history says to scrutinize hardest.

### 13. L-1 through L-5

All five diffed and confirmed present exactly as described:
- **L-1:** `registeredSpecs()` javadoc corrected from "`CONFIGURED_JOB_NAMES` order" to describe the `TreeMap`/alphabetical-key ordering.
- **L-2:** `TriggerSpec.of()` now calls `Objects.requireNonNull(cronExpression, "cronExpression")` before `isZoneInvariant`'s `.trim()`. New test `ofRejectsNullCronWithANamedException` asserts the message contains `"cronExpression"`.
- **L-3:** Confirmed the pre-fix indentation defect directly (`git show 7b7db3b6:.../TriggerSpec.java` lines 18-20 use `     * ` five-space indent instead of ` * `); diff shows it corrected.
- **L-4:** `Math.toIntExact(tenantId)` narrowed to its own try/catch immediately after `tenantId` is read, before the lock/business-logic try block; the outer generic `catch (Exception e)` javadoc-comments that an `ArithmeticException` reaching it can now only be a real `cleanupStaleBatches()` bug. New test `int4OverflowIsNamedAtTheJobLevel` asserts `tryLock` is `never()` called for the overflowing id.
- **L-5:** Regex patterns in `outboxAndIdempotencyStayOneKey` anchored from `tryLock\([^)]*,[^)]*\)` to `advisoryLockService\.tryLock\([^)]*,[^)]*\)` (and same for `unlock`).

### 14–15. L-6/L-7/L-8 deferred, L-9 informational — scope sanity check

Confirmed no silent regression in the deferred areas:
- **L-6** (`"No tenants configured. Skipping {} for {}."` firing once per group): line present unchanged at `:127` of the new file, not touched by this PR's diff.
- **L-7** (`getWarehouseZoneId(current.getFacilityCode())` using the explicit-facility overload where the no-arg one would do): line present unchanged (moved a few lines down only because M-4 reordered the guard, not because its own logic changed) — still the explicit-facility overload, unchanged.
- **L-8** (no end-to-end pin that both derivation sides use the same method): no new test file or method targets this; confirmed no test in the diff exercises real-registration-against-real-firing-derivation together.
- **L-9** (informational design-doc claim check): no corresponding code or test change in the diff, consistent with "informational, no action."

### 16. "1 High, 6 Medium, 9 Low" review-count claim

Grepped `sbdocs/1-Projects/wms2/plan/SBDEV-3198-evidence/step3-review-code.md` for finding headers: exactly one `H-1`, six `M-` findings (`M-2` through `M-7` — no `M-1`, consistent with the numbering the review itself uses), and nine `L-` findings (`L-1` through `L-9`). Matches "1 High, 6 Medium, 9 Low" exactly, and the fixed/deferred/informational split (5/3/1) matches the PR's own per-item breakdown verified in sections 13–15 above.

## Bottom line

16 checkable claims examined. **15 PASS, 1 FAIL (M-6's "five" undercounts the actual 11 literal replacements), 1 UNVERIFIED-IN-THIS-PASS** (the H-1 mutation-testing claim, which the PR body itself frames as a prior pass's result, not something this pass reconstructed). The headline suite numbers (6225/0/67 head, 6218/0/67 baseline, delta +7) all reproduced **exactly** via direct, freshly-run `mvn -q -o clean test` measurements at both commits in the isolated worktree — including the baseline, which the PR only "derived" but which I independently re-measured and confirmed matches to the digit.
