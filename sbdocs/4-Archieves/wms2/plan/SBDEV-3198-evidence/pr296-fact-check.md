# PR #296 fact-check — SBDEV-3198 follow-up (CleanUpOldMessagesJob activation gate)

Independent fact-check of every checkable, specific, quantitative or historical claim in
[PR #296](https://github.com/SiteBossInc/wms2-api/pull/296) (`e7c844b7`). Scope: claims only, not
code-correctness review (a separate lane covers that). Worktree:
`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-296-review-fact`, detached HEAD
at `e7c844b7`.

## Verdict table

| # | Claim | Verdict | Detail |
|---|---|---|---|
| 1 | `git show e83d9550` proves pre-D′ `doCalculation(Boolean)` ran the manual trigger through an activation-gated shared loop | PASS | §1 |
| 2 | Full suite: 6265/0/0/67 | PASS | §2 |
| 3 | Four existing tests fixed, two new tests added — the 7 named methods all exist in the diff | PASS | §3 |
| 4 | PIT on `CleanUpOldMessagesJob`: 84% kill rate | PASS | §4 |
| 5 | Only `CleanUpOldMessagesJob.java` and its two directly-affected test files changed | PASS | §5 |
| 6 | Hand-mutation (`return true`→`return false` in `runForCurrentTenant()`'s success path) caught by 4 tests across two files | PASS | §6 |

**6/6 PASS. No failures.**

---

## 1. The central historical claim — `git show e83d9550`

Ran directly from the worktree:

```
git show e83d9550:src/main/java/net/aim_ai/wms/schedulejob/CleanUpOldMessagesJob.java
```

Commit identity confirmed first:

```
$ git show -s --format='%H %s' e83d9550
e83d9550e73c1615a8ede2acafe5db230b3d7822 SBDEV-3198 AC13(b): "run now" means the caller's tenant, not every tenant
```

and its position relative to the D′ conversion, via `git log --ancestry-path`:

```
e7c844b7 SBDEV-3198 follow-up: restore CleanUpOldMessagesJob's manual-trigger activation gate
...
c360b380 Merge pull request #291 from SiteBossInc/bugfix/SBDEV-3198-cleanup-old-messages
685670d6 SBDEV-3198 step 5 (1/4) review round 2: fix N-1/N-2/N-3/N-4 (PR #291)
15c6a901 SBDEV-3198 step 5 (1/4) review round 1: fix M-1/M-2/L-1/L-2/L-4/L-5 (PR #291)
55ec08e1 SBDEV-3198 step 5 (1/4): convert CleanUpOldMessagesJob to D'
```

`e83d9550` is the commit immediately preceding `55ec08e1` (the D′ conversion) — matches the PR's
characterization of it as "the commit immediately before PR #291's D′ conversion."

The file content at that commit (relevant excerpt):

```java
public void doCalculation(Boolean isCronJob) {
    ...
    final boolean scheduled = Boolean.TRUE.equals(isCronJob);
    final TenantProfile callerTenant = scheduled ? null : TenantContext.getCurrentTenant();
    ...
    try {
        List<TenantProfile> tenantProfiles;
        if (scheduled) {
            tenantProfiles = tenantDbConfigurationRepository.findByActiveTrue()...;
            ...
        } else {
            // Exactly one tenant, so the loop below is unchanged. findByActiveTrue() is not
            // consulted at all on this path...
            tenantProfiles = List.of(callerTenant);
        }

        boolean anyFailure = false;
        for (TenantProfile tenantProfile : tenantProfiles) {
            ...
            try {
                ...
                if (!Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY))
                    || !Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY))) {
                    LOG.info("cleanUpOldMessagesJob not activated for for {} - {}", ...);
                    jobMetrics.tenantSkippedNotActivated(tenantName);
                    continue;
                }
                archiveOldMessages();
                ...
```

**Match confirmed.** The manual path (`isCronJob == false`) builds `tenantProfiles = List.of(callerTenant)`
— a single-element list — and that list is fed through the exact same `for` loop, with the exact same
two-sysprop activation check (`SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY` OR'd with
`SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY`), as the scheduled path. The PR's quoted snippet
is a faithful (if lightly excerpted) transcription of the real code — no embellishment, no distortion.
The characterization "ran the manual trigger through the same activation-gated shared loop" is accurate.

## 2. Full suite: 6265/0/0/67

Ran `mvn -o clean test` end-to-end (3m50s, `BUILD SUCCESS`), then independently summed every
`target/surefire-reports/*.txt` file with a script (not trusting Maven's own printed total):

```
files=1683 tests=6265 failures=0 errors=0 skipped=67
```

Maven's own summary line agrees:

```
[WARNING] Tests run: 6265, Failures: 0, Errors: 0, Skipped: 67
[INFO] BUILD SUCCESS
```

**Exact match** to the PR's "6265/0/0/67 (0 failures, 0 errors)".

## 3. Test surgery — 4 fixed + 2 new, named methods

`git merge-base origin/develop e7c844b7` → `56fc1035c92b4f2e26ab3d9ea649c6aa9d0dd4f2`. Diffed against
that base:

```
git diff --stat 56fc1035..e7c844b7
 .../wms/schedulejob/CleanUpOldMessagesJob.java     | 46 ++++++++++++++++-----
 .../AdminTriggerTenantScopeUnitTest.java           | 18 +++++++--
 .../schedulejob/CleanUpOldMessagesJobUnitTest.java | 47 ++++++++++++++++++++++
 3 files changed, 97 insertions(+), 14 deletions(-)
```

All 7 named methods confirmed present with the expected changes:

- `AdminTriggerTenantScopeUnitTest$CleanUpOldMessages.adminTrigger_runsOnlyTheCallersTenant` — diff
  adds the two `syspropService` stubs (`NEW_CRON_JOB_ACTIVATED_KEY`, `CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY`
  both `"true"`) before the call, with a comment explaining why (STRICT_STUBS rejects the old
  one-key `activated()` helper here since it stubs an unused tryLock).
- `AdminTriggerTenantScopeUnitTest$CleanUpOldMessages.adminTrigger_leavesTheCallersContextIntact` —
  same two stubs added; old comment claiming "no activation-flag check" replaced with a comment
  explicitly stating that claim was the bug; assertion tightened from ignoring the return value to
  `assertThat(ran).isTrue()`.
- `CleanUpOldMessagesJobUnitTest$RunForCurrentTenantLocking.returnsFalseAndStillUnlocksWhenArchiveThrows` —
  two activation stubs added before the `doThrow(...)` setup.
- `CleanUpOldMessagesJobUnitTest$RunForCurrentTenantLocking.locksOnTheCallersOwnTenantId` — two
  activation stubs added.
- `CleanUpOldMessagesJobUnitTest$RunForCurrentTenantLocking.doesNotTouchTheWholeRunGauges` — two
  activation stubs added.
- `CleanUpOldMessagesJobUnitTest$RunForCurrentTenantLocking.refusesWhenNotActivated` — **new test**,
  stubs `NEW_CRON_JOB_ACTIVATED_KEY="true"` / `CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY="false"`, asserts
  `ran` is `false`, `archiveMessage()` never called, lock still released.
- `CleanUpOldMessagesJobUnitTest$RunForCurrentTenantLocking.refusesWhenGlobalCronSwitchOff` — **new
  test**, stubs `NEW_CRON_JOB_ACTIVATED_KEY="false"` only (comment correctly notes the `||`
  short-circuits so the second key is never read — stubbing it would be an UnnecessaryStubbing under
  STRICT_STUBS), asserts `ran` is `false`.

All 7 names match exactly; behavior of each diff hunk matches the PR's description of it.

## 4. PIT: 84% kill rate

Per the known stale-bytecode trap noted in the task brief, ran with `clean test-compile` first to force
recompilation:

```
mvn -o clean test-compile org.pitest:pitest-maven:mutationCoverage \
  -DtargetClasses=net.aim_ai.wms.schedulejob.CleanUpOldMessagesJob \
  -DtargetTests='net.aim_ai.wms.unit.schedulejob.CleanUpOldMessagesJob*,net.aim_ai.wms.unit.schedulejob.AdminTriggerTenantScopeUnitTest,net.aim_ai.wms.unit.schedulejob.WholeRunSuccessGaugeUnitTest'
```

Output:

```
>> Line Coverage (for mutated classes only): 121/140 (86%)
>> 15 tests examined
>> Generated 56 mutations Killed 47 (84%)
>> Mutations with no coverage 1. Test strength 85%
>> Ran 204 tests (3.64 tests per mutation)
```

**Exact match**: 47/56 = 84% kill rate, as claimed. (9 survivors + 1 no-coverage = the "remaining
survivors" the PR attributes to pre-existing, unrelated causes — this fact-check did not individually
re-derive each survivor's root cause, only the aggregate percentage and mutation/kill counts, which
were the specific numeric claims in the PR.)

## 5. Scope — only 3 files changed

```
$ MB=$(git merge-base origin/develop e7c844b7); git diff --name-only $MB..e7c844b7
src/main/java/net/aim_ai/wms/schedulejob/CleanUpOldMessagesJob.java
src/test/java/net/aim_ai/wms/unit/schedulejob/AdminTriggerTenantScopeUnitTest.java
src/test/java/net/aim_ai/wms/unit/schedulejob/CleanUpOldMessagesJobUnitTest.java
```

Exactly 3 files, exactly the ones named — the main class plus its two "directly-affected" test files.
Nothing outside that set changed. **Confirmed.**

Additionally spot-checked the main-file diff content: the activation check inserted into
`runForCurrentTenant()` (after the two-key `tryLock`, inside the `try`) checks
`SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY` then `SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY`
— the same two flags, in the same order, as `runFor()`'s own check (confirmed via
`grep -n` on both call sites: `runFor()` at line 234-235, `runForCurrentTenant()` at line 353-354,
identical key order). Matches the PR's "checking the same two sysprops `runFor()` checks, in the same
order" claim.

## 6. Hand-mutation: 4 tests catch the success-path flip

Edited `runForCurrentTenant()` at the working file (not committed), flipping only the success-path
return:

```diff
             archiveOldMessages();
-            return true;
+            return false;
         } catch (Exception e) {
```

Ran the two named test classes:

```
mvn -o clean test -Dtest='CleanUpOldMessagesJobUnitTest,AdminTriggerTenantScopeUnitTest'
```

Result: `EXIT_CODE=1`, with:

```
[ERROR] Tests run: 8, Failures: 2, ... in CleanUpOldMessagesJobUnitTest$RunForCurrentTenantLocking
[ERROR] Tests run: 4, Failures: 2, ... in AdminTriggerTenantScopeUnitTest$CleanUpOldMessages
[ERROR] Tests run: 26, Failures: 4, Errors: 0, Skipped: 2
```

Failing methods, by name:

```
AdminTriggerTenantScopeUnitTest$CleanUpOldMessages.adminTrigger_leavesTheCallersContextIntact:334
AdminTriggerTenantScopeUnitTest$CleanUpOldMessages.adminTrigger_runsOnlyTheCallersTenant:290
CleanUpOldMessagesJobUnitTest$RunForCurrentTenantLocking.doesNotTouchTheWholeRunGauges:294
CleanUpOldMessagesJobUnitTest$RunForCurrentTenantLocking.locksOnTheCallersOwnTenantId:276
```

**Exactly 4 failures across exactly 2 files**, as claimed. (`returnsFalseAndStillUnlocksWhenArchiveThrows`
and the two new `refusesWhen*` tests correctly did not fail — they exercise the exception path / the
activation-refusal path, neither of which passes through the mutated `return true` statement, so their
immunity to this particular mutation is expected, not a gap.)

File restored immediately after:

```
git checkout -- src/main/java/net/aim_ai/wms/schedulejob/CleanUpOldMessagesJob.java
git status --short   # clean
```

Confirmed the restored file has `return true;` back in place (`sed -n '355,362p'`) and the working tree
is clean.

---

## Summary of method

All 6 claims were re-derived independently rather than trusted: `git show`/`git diff`/`git log
--ancestry-path` for the historical and scope claims, a from-scratch Python summation of every
`surefire-reports/*.txt` file for the test-count claim (not Maven's own printed total), a real PIT run
with forced recompilation for the mutation-coverage claim, and a live hand-mutation + restore for the
mutation-adequacy claim. No claim required trusting the PR's own prose.
