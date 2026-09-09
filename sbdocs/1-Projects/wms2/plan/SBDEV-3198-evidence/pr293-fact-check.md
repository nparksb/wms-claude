---
name: pr293-fact-check
description: Independent fact-check of PR #293 (SBDEV-3198 step 5, part 2/4 — ReleaseExpiredPickingOrdersFromUserJob D' conversion)
metadata:
  lane: fact-check
  status: reviewed
  base: c360b380ee234ff78a7c4d2f4a91445ed001bf60 (merge-base with origin/develop)
  head: 64fb9223387cbfb3e81cd18f7570eb7621efb761 (bugfix/SBDEV-3198-release-expired-picking, PR #293)
  worktree: /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-293-review-fact
---

# PR #293 fact-check

Adversarial re-derivation of every checkable, specific, quantitative or completeness claim in PR
#293's description (`gh pr view 293 --repo SiteBossInc/wms2-api`), independent of code-correctness
review (a separate lane). Every number below was reproduced with an independent instrument, not
read off the PR text.

Toolchain: `export SDKMAN_DIR="$HOME/.sdkman"; source "$SDKMAN_DIR/bin/sdkman-init.sh"`; Java
21.0.11, Maven (sdkman current). All commands run from the worktree root above.

## Verdict table

| # | Claim | Verdict | Detail |
|---|---|---|---|
| 1 | Full suite: 6262/0/0/67 | **PASS** | Independently summed every surefire report, see §1 |
| 2 | "9 test files touched" | **FAIL** | Actual is 8, two instruments agree, see §2 |
| 3 | NeverMatcher census "156→163 across 39 classes, +7" | **FAIL (partial)** | Base is 154 not 156, delta is +9 not +7; end value 163 and the per-class figure of 9 are both correct — see §3 |
| 4 | Idempotency: query filters on the exact column the write flips | **PASS** | Native SQL and write path both quoted, see §4 |
| 5 | SchedulingConfiguration: one hardcoded cron, no per-tenant sysprop | **PASS** | Method read verbatim, see §5 |
| 6 | PIT: kill rate 67%→81%, zero NO_COVERAGE, named survivor breakdown | **PASS** (81%/zero NO_COVERAGE/breakdown reproduced; 67% baseline unverifiable) | See §6 |
| 7 | Two boolean-return survivors are a PIT bytecode-attribution artifact, not a real gap | **PASS** | Hand-mutated and confirmed test failure, see §7 |
| 8 | AC-3 reworked: `skipped_lock_busy` never increments in this job's shape | **PASS** | No call site exists in the class, see §8 |

**6 of 8 fully PASS, 1 clean FAIL (§2), 1 partial FAIL on an aggregate arithmetic error whose
underlying per-class figure is correct (§3).**

---

## §1 — Full suite: 6262/0/0/67

Ran `mvn -o clean test` in the fact-check worktree (checked out at `64fb9223`). Console tail read
`Tests run: 6262, Failures: 0, Errors: 0, Skipped: 67` and `BUILD SUCCESS`, but per instruction that
alone is not trusted — independently summed **every** `target/surefire-reports/*.txt` file:

```
files: 1681
Tests run: 6262 Failures: 0 Errors: 0 Skipped: 67
```

Exact match, both instruments agree.

## §2 — "9 test files touched"

```
git merge-base origin/develop 64fb9223
→ c360b380ee234ff78a7c4d2f4a91445ed001bf60

git diff --name-status c360b380..64fb9223 -- src/test   → 8 files (all "M")
git diff --stat        c360b380..64fb9223 -- src/test   → 8 files changed, 353(+), 74(-)
```

Both instruments agree: **8**, not 9. File list:
`SchedulingConfigurationUnitTest.java`, `NeverMatcherNullBlindnessArchTest.java`,
`AdminActionControllerUnitTest.java`, `AdminTriggerTenantScopeUnitTest.java`,
`ReleaseExpiredPickingOrdersFromUserJobMetricsUnitTest.java`,
`ReleaseExpiredPickingOrdersFromUserJobTest.java`,
`ReleaseExpiredPickingOrdersFromUserJobUnitTest.java`, `WholeRunSuccessGaugeUnitTest.java`.

This is the **same 8 files the PR body's own "Test surgery" section names** — the sentence "9 test
files touched" is simply wrong; the actual count matches the named list beneath it, not the number
in front of it.

## §3 — NeverMatcher census "156→163 across 39 classes, +7"

`PRIMITIVE_MATCHER_INVENTORY` in
`src/test/java/net/aim_ai/wms/unit/config/NeverMatcherNullBlindnessArchTest.java`.

**At HEAD (64fb9223):** extracted all 39 `"ClassName:count"` entries and summed independently
(Python, not by eye):

```
head sum = 163, n = 39
```

**At merge-base (c360b380):** same extraction:

```
base sum = 154, n = 39
delta = 9
```

The two commits differ only in two entries: `AdminTriggerTenantScopeUnitTest` (2→4) and
`ReleaseExpiredPickingOrdersFromUserJobTest` (2→9). `(4-2) + (9-2) = 2 + 7 = 9`, confirming the
independent sum.

**So the PR's "156→163, +7" is wrong on both the base (156 vs actual 154) and the delta (+7 vs
actual +9).** The end value (163) and class count (39) are correct.

The specific figure `"ReleaseExpiredPickingOrdersFromUserJobTest:9"` **is** correct, verified two
ways:
1. Grepped the actual test file for `never()` call sites (7 total), then inspected each for
   primitive-matcher arguments (`anyInt()`/`anyLong()`), counting **occurrences** not call sites:
   lines 199 (`anyInt()`×1), 218 (`anyInt()`×1), 467 (`anyLong()`×1), 497 (`anyLong()`×2), 511
   (`anyLong()`×2), 527 (`anyLong()`×2) = 1+1+1+2+2+2 = **9**. (Line 263, `never().save(any())`, has
   no primitive matcher and is correctly excluded.)
2. This matches the method's own javadoc breakdown at
   `NeverMatcherNullBlindnessArchTest.java:395-397`: "one `tryLock(JobLockId, anyLong())` site (1),
   two `tryLock(anyLong(), anyLong())` sites... (2 + 2), and one `unlock(anyLong(), anyLong())` site
   (2) — plus the two pre-existing `anyInt()`" = 1+2+2+2+2 = 9.

So this is a real, if narrow, defect: the per-class figure and the counting methodology are sound,
but the PR's own arithmetic in stating the aggregate before/after numbers is wrong.

## §4 — Idempotency: query filters on the exact column the write flips

`releaseExpiredPickingOrders()` at
`src/main/java/net/aim_ai/wms/schedulejob/ReleaseExpiredPickingOrdersFromUserJob.java:257-272`:

```java
List<Pickingorder> pickingOrders = pickingorderRepository.getPickingOrdersToReleaseExpiredPickingOrders(...);
for (Pickingorder pickingOrder : pickingOrders) {
    ...
    pickingOrder.setOperatorId(null);
    pickingOrder.setLockedtooperator(false);
    pickingorderRepository.save(pickingOrder);
}
```

`PickingorderRepository.getPickingOrdersToReleaseExpiredPickingOrders` at
`src/main/java/net/aim_ai/wms/repo/jpa/PickingorderRepository.java:91-100`, native query:

```sql
SELECT DISTINCT po.* FROM pickingorder_position pop
 INNER JOIN pickingorder po ON pop.pickingorder_id = po.id
 INNER JOIN section s ON po.section_id = s.id
 WHERE po.lockedtooperator = true
 AND po.pickinginprogress = false
 AND po.modified < :timeOut
 AND po.state < :state
 AND s.sectionpickingtype = :pickingType
```

Confirmed: the query's `po.lockedtooperator = true` predicate is exactly the column the write flips
to `false`. Once a row is updated, a second concurrent run's `SELECT` no longer matches it — the
idempotency reasoning holds. One minor imprecision in the PR's own wording: it calls this "a plain
`UPDATE`", but it is actually a `SELECT` followed by a per-row JPA entity mutation + `save()`, not a
single SQL `UPDATE` statement — functionally equivalent for the idempotency argument, but not
literally an `UPDATE`. Not counted as a FAIL since the substantive claim (which column, which
direction, why concurrent runs converge) is accurate.

## §5 — SchedulingConfiguration: one hardcoded cron, no per-tenant sysprop

`configureReleaseExpiredPickingOrdersFromUser` at
`src/main/java/net/aim_ai/wms/schedulejob/SchedulingConfiguration.java:942-957`:

```java
private boolean configureReleaseExpiredPickingOrdersFromUser(TaskScheduler scheduler, String scheduleSource) {
    try {
        boolean showLog = Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_CRON_JOB_SHOW_LOG_KEY));
        String cronjob = "40 * * * * *";
        register("releaseExpiredPickingOrdersFromUser", scheduler, cronjob, () -> {
            if (showLog) LOG.info(...);
            releaseExpiredPickingOrdersFromUserJob.runFor();
        }, scheduleSource);
        return true;
    } catch (Exception e) { ... }
}
```

Confirmed: a single hardcoded cron string, one `register(...)` call, no `TriggerSpec` derivation, no
sysprop read for timing (the only sysprop read is `SYSTEM_PROPERTY_CRON_JOB_SHOW_LOG_KEY`, a logging
flag, not a schedule). Matches the claim exactly.

## §6 — PIT: kill rate 67%→81%, zero NO_COVERAGE

First attempt (`mvn -o org.pitest:pitest-maven:mutationCoverage ...` as a direct goal invocation,
no preceding `clean`) failed at its own baseline coverage step with 3 tests failing without
mutation — traced to stale `target/classes` bytecode left over from §7's hand-mutation (a direct
goal invocation does not force a recompile, and `git checkout --` restores source but not compiled
classes). Reran with a forced `mvn -o clean test-compile org.pitest:pitest-maven:mutationCoverage
-DtargetClasses=net.aim_ai.wms.schedulejob.ReleaseExpiredPickingOrdersFromUserJob
-DtargetTests='net.aim_ai.wms.unit.schedulejob.ReleaseExpiredPickingOrdersFromUserJob*,net.aim_ai.wms.unit.schedulejob.AdminTriggerTenantScopeUnitTest,net.aim_ai.wms.unit.schedulejob.WholeRunSuccessGaugeUnitTest'`
— `BUILD SUCCESS`:

```
Line Coverage (for mutated classes only): 105/110 (95%)
Generated 42 mutations, Killed 34 (81%)
Mutations with no coverage: 0. Test strength 81%
```

**81% and zero NO_COVERAGE both confirmed exactly.** The pre-fix "67%" baseline cannot be
independently reproduced — it describes an ephemeral pre-PR development state that was fixed before
the branch was pushed, not a state that exists as a separate git commit, so there is nothing to
check it out and rerun against. Not counted as a FAIL; it is simply outside what git history can
verify.

Parsed `target/pit-reports/mutations.xml` for the actual 8 SURVIVED mutations (42-34=8, consistent):

| Line | Mutator | Method | Description |
|---|---|---|---|
| 167 | NegateConditionals | `runFor` | negated conditional |
| 175 | Math | `runFor` | subtraction→addition |
| 185 | VoidMethodCall | `runFor` | removed `stopTenantTimer` call |
| 186 | VoidMethodCall | `runFor` | removed `TenantContext::clear` call |
| 192 | Math | `runFor` | subtraction→addition |
| 248 | BooleanTrueReturnVals | `runForCurrentTenant` | forced `true` |
| 251 | BooleanFalseReturnVals | `runForCurrentTenant` | forced `false` |
| 266 | NegateConditionals | `releaseExpiredPickingOrders` | negated conditional |

Read the source at each line to classify them against the PR's named survivor categories:
- Lines 167, 266 are both `if (basicService.showLog())` guards — **the "two log-conditional
  mutants"**, confirmed.
- Lines 175, 192 are both `System.currentTimeMillis() - start` / `System.nanoTime() - startNanos`
  duration calculations — **the "two duration-calc arithmetic mutants"**, confirmed.
- Lines 185, 186 are the `stopTenantTimer`/`TenantContext.clear()` calls in the outer `finally` —
  **"unasserted `stopTenantTimer`/`TenantContext.clear()` calls"**, confirmed, one each.
- Lines 248, 251 are the two `runForCurrentTenant()` boolean-return survivors — **"two equivalent
  no-op boolean-return mutants"**, confirmed, and independently hand-verified in §7.

All 8 survivors map exactly onto the PR's named breakdown, 2+2+2+2=8. Full match.

## §7 — Boolean-return survivors are a bytecode-attribution artifact, not a real gap

Backed up the source file, then edited
`ReleaseExpiredPickingOrdersFromUserJob.java:246-254`'s success path:

```diff
         try {
             releaseExpiredPickingOrders();
-            return true;
+            return false;
         } catch (Exception e) {
```

Ran `mvn -o test -Dtest=ReleaseExpiredPickingOrdersFromUserJobTest`:

```
[ERROR]   ReleaseExpiredPickingOrdersFromUserJobTest$RunForCurrentTenantLocking.doesNotTouchTheWholeRunGauges:584
Expecting value to be true but was false
[ERROR]   ReleaseExpiredPickingOrdersFromUserJobTest$RunForCurrentTenantLocking.returnsTrueAndReleasesLockOnSuccess:564
Expecting value to be true but was false
[ERROR] Tests run: 20, Failures: 2, Errors: 0, Skipped: 0
BUILD FAILURE
```

The mutation is caught (2 failures) — a genuine source-level flip of the same semantic change PIT's
`BooleanTrueReturnValsMutator`/`BooleanFalseReturnValsMutator` reported as SURVIVED is in fact
detected by the suite, supporting the PR's claim that the PIT survivors are a bytecode
line-attribution artifact (PIT mutating the `finally`-adjacent bytecode in a way its own line
number can't distinguish from a genuinely uncovered branch) rather than a real assertion gap.
Restored the file with `git checkout -- src/main/java/net/aim_ai/wms/schedulejob/ReleaseExpiredPickingOrdersFromUserJob.java`
immediately after and confirmed `git status --short` was clean before continuing.

## §8 — AC-3 reworked: `skipped_lock_busy` never increments in this job

`LockBusy` nested test class in
`ReleaseExpiredPickingOrdersFromUserJobMetricsUnitTest.java:106-134` asserts
`registry.find("wms2.cron.release_expired_picking.skipped_lock_busy").counter()` is `null` on the
two-key lock-busy path.

Confirmed against the main-code lock-busy branch in `runFor()`
(`ReleaseExpiredPickingOrdersFromUserJob.java:152-156`): on `tryLock` failure it logs and `continue`s
with **no** `jobMetrics` call of any kind.

Independently grepped for the metric's increment call across every scheduled job:

```
CleanUpOldMessagesJob.java:213:      jobMetrics.skippedLockBusy();
StockSummaryExportJob.java:276:      jobMetrics.skippedLockBusy();
ReplenishOrderJob.java:120:          jobMetrics.skippedLockBusy();
OrderReleaseJob.java:87:             jobMetrics.skippedLockBusy();
```

`ReleaseExpiredPickingOrdersFromUserJob.java` has **zero** matches — it is the only job of the five
that never calls `jobMetrics.skippedLockBusy()` anywhere in its source. The claim that this job's
D′ shape genuinely never increments the metric on the two-key busy path is accurate.
