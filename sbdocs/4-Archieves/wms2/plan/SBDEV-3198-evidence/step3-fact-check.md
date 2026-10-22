# SBDEV-3198 PR #286 fact-check — step 3 claims

Independent fact-check lane on `wms2-api` PR #286, branch `bugfix/SBDEV-3198-dprime-stale-club`,
commit `a35cab5a`, based on `e818ff11`. Scope: every checkable claim in
`SBDEV-3198-per-tenant-cron-scheduling.md` §7a step "3." (lines 1391–1465, the "PR SUBMITTED
2026-09-02" block), stopping before the "MUST READ before converting `StockSummaryExportJob`"
subsection per instructions (that subsection is a decision about a different, later job).

Worked in isolated worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-DPRIME-review-b`
(detached HEAD at `a35cab5a`). No `git stash` used; no other worktree touched.

Verdict key: **PASS** = independently re-derived and matches. **FAIL** = does not match. **UNVERIFIABLE**
= could not be checked from this session (reason given).

---

## 1. PR identity: PR #286, commit `a35cab5a`, branch `bugfix/SBDEV-3198-dprime-stale-club`, rebased onto `e818ff11`

**Check:** `git log --oneline -3` in the worktree; `git rev-parse HEAD`.

```
a35cab5a SBDEV-3198 D' shape, proof of concept: StaleClubBatchCleanupJob converted
e818ff11 SBDEV-3205: pick-timeout release query selected nothing — fix the operator/lock polarity (#284)
951b854c Merge pull request #283 from SiteBossInc/bugfix/SBDEV-3198-ac14-converging-registration
```

**PASS** — HEAD is `a35cab5a`, directly on top of `e818ff11`. (Branch name and PR number are GitHub
metadata I did not independently re-check via `gh`, but commit/parentage matches exactly.)

---

## 2. "Full suite 6216/0 vs a freshly-measured baseline `e818ff11` 6173/0 — exactly +43"

**Check:** No `mvn`/`java` on `PATH` initially (per repo history — toolchain off `PATH`); found both
under `~/.sdkman/candidates/{java/21.0.11-ms,maven/current}` and added them to `PATH` for this
session.

**Directly measured, both revisions, in this worktree (mine alone; restored to `a35cab5a` afterward):**

- First attempt used `-Dtest='!*IT'`, which — I discovered the hard way — **overrides** the pom's own
  `<excludes>**/*IntegrationTest.java</excludes><excludes>**/*E2ETest.java</excludes>` (Surefire
  config at `pom.xml:551-555`), so it pulled in `*IntegrationTest`/`*E2ETest` classes the real "full
  suite" lane never runs, plus it hit real environment failures (Testcontainers/Flyway-dependent
  tests needing Docker) unrelated to this PR. Recognized and discarded this run.
- Reran with plain `mvn -q -o test` (no `-Dtest` override, honoring the pom excludes) at HEAD
  (`a35cab5a`), after `rm -rf target/surefire-reports` to avoid stale reports from the discarded run
  contaminating the sum (confirmed via mtimes that the first `mvn test` attempt without a report wipe
  silently mixed stale + fresh reports — a real trap, not hypothetical). Summed `Tests run/Failures/
  Errors/Skipped` across all 1672 `target/surefire-reports/*.txt` files:

  **`a35cab5a` (HEAD): Tests run: 6216, Failures: 0, Errors: 0, Skipped: 67.**

- Then, in this same worktree, `git checkout e818ff11` (mine alone; restored to `a35cab5a` afterward)
  and ran `mvn -q -o clean test` (full clean rebuild, so no stale `.class`/report contamination across
  the commit boundary). Summed across all 1664 `target/surefire-reports/*.txt` files:

  **`e818ff11` (baseline): Tests run: 6173, Failures: 0, Errors: 0, Skipped: 67.**

- `6216 − 6173 = 43`, and `0/0` on both sides.

**Verdict: PASS — exact match on all three numbers** (`6216/0`, `6173/0`, and the `+43` delta), from a
from-scratch full-suite run on both commits, not merely reconstructed from source-level counts. (The
arithmetic reconstruction below was done first, before the full runs completed, and is kept as
corroborating evidence — it independently arrived at the same +43 via a completely different method.)

**Arithmetic cross-check (independent reconstruction, done before the full run above finished):**
Reconstructed the delta from real Surefire per-file test-run counts (not just `grep -c @Test`, which
undercounts `@ParameterizedTest`/`@RepeatedTest` expansion) by running the 8 touched test classes alone
via `mvn -Dtest=<8 classes> test` and summing `Tests run:` across each class's `.txt` + nested-class
`.txt` reports (JUnit 5 `@Nested` classes report separately from the outer class), then diffing against
the same computation on `e818ff11` (via `git show e818ff11:<path> | grep`, cross-checked for
`@ParameterizedTest`/`@RepeatedTest` annotations at baseline too):

| File | baseline actual | current actual | delta |
|---|---|---|---|
| `SchedulingConfigurationUnitTest` | 33 | 42 | **+9** |
| `SchedulingReconcileIdempotencyUnitTest` (has one `@RepeatedTest(value=8)`, unchanged both sides: 21 `@Test` + 8 repetitions = 29) | 29 | 29 | 0 |
| `TriggerSpecUnitTest` (NEW; 4 `@Test` + 2 `@ParameterizedTest` methods expanding to 3+5 `@ValueSource` cases = 12 actual) | 0 (didn't exist) | 12 | **+12** |
| `NeverMatcherNullBlindnessArchTest` | 4 | 4 | 0 |
| `AdminTriggerTenantScopeUnitTest` | 16 | 16 | 0 |
| `StaleClubBatchCleanupJobUnitTest` | 2 | 14 | **+12** |
| `WholeRunSuccessGaugeUnitTest` | 20 | 20 | 0 |
| `AdvisoryLockServicePerTenantLockUnitTest` (NEW) | 0 | 10 | **+10** |
| **Total** | | | **+43** |

9 + 12 + 12 + 10 = **43**, exactly matching the claimed delta. This is strong corroborating evidence
for "+43" specifically, verified via actual Surefire execution counts (not source grep) on both the
current commit and a reconstruction of baseline annotation shape.

**Verdict on "+43" via reconstruction: PASS**, and superseded by the full direct measurement above,
which confirms it exactly by a second, independent method.

---

## 3. "cross-checked against the five changed test files' own counts including `@ParameterizedTest` cases"

**Check:** `git diff e818ff11 a35cab5a --name-status` — 12 files changed total: 4 main + 8 test files
(6 Modified, 2 Added: `TriggerSpecUnitTest.java`, `AdvisoryLockServicePerTenantLockUnitTest.java`).

Of those **8** changed test files, only **4** carry a nonzero test-count delta (see table above):
`SchedulingConfigurationUnitTest`, `TriggerSpecUnitTest`, `StaleClubBatchCleanupJobUnitTest`,
`AdvisoryLockServicePerTenantLockUnitTest`. The other 4 changed test files
(`SchedulingReconcileIdempotencyUnitTest`, `NeverMatcherNullBlindnessArchTest`,
`AdminTriggerTenantScopeUnitTest`, `WholeRunSuccessGaugeUnitTest`) were genuinely edited (rewritten
assertions / inventory entries) but their test *counts* are unchanged (0 delta each), and they are not
needed to reach +43.

**FAIL** — the completeness word is off by one. The +43 is fully accounted for by **four** files, not
five, whether you count "files with a nonzero test-count delta" (4) or "all changed test files" (8).
This is exactly the class of completeness-word slip this repo's own history flags as the most common
break. The underlying arithmetic (+43) is still correct — only the file-count language is wrong.

---

## 4. "It is the smallest job (77 lines)"

**Check:** `git show e818ff11:.../StaleClubBatchCleanupJob.java | wc -l` = 77. Compared line counts of
all 8 `schedulejob/*Job.java` files at baseline `e818ff11`:

```
 77  StaleClubBatchCleanupJob.java   <- smallest
 81  RestIdempotencyCleanupJob.java
113  OutboxDispatcherJob.java
153  CleanUpOldMessagesJob.java
162  ReleaseExpiredPickingOrdersFromUserJob.java
381  OrderReleaseJob.java
384  StockSummaryExportJob.java
552  ReplenishOrderJob.java
```

**PASS** — 77 lines, smallest of all 8 job files, and also smallest of the six `app.cron` jobs the
plan's step 4/5/6 sequence names (`StockSummaryExportJob`, `CleanUpOldMessagesJob`,
`ReleaseExpiredPickingOrdersFromUserJob`, `OrderReleaseJob`, `ReplenishOrderJob`).

---

## 5. "has 2 `doCalculation` call sites in tests"

**Check:** `git show e818ff11:.../StaleClubBatchCleanupJobUnitTest.java | grep -n "doCalculation("`
→ 2 sites (lines 53, 76 of that old-path test file, both `job.doCalculation(true)`). Grepped every
other baseline test file referencing `StaleClubBatchCleanupJob` for a third call site — none found.

**PASS** — exactly 2 call sites at baseline, matching.

---

## 6. "uses `JobMetrics` not at all — zero metric blast radius"

**Check:** `grep -n "JobMetrics" src/main/java/.../StaleClubBatchCleanupJob.java` — the only hit is the
class javadoc's own prose ("has no `JobMetrics` at all"), not a usage. Also checked
`StaleClubBatchCleanupJobService.java` (unmodified, but part of the job's execution path) — zero hits.

**PASS**.

---

## 7. "'already honours `isCronJob`' was false... the flag only ever skipped the activation check"

**Check:** Read `StaleClubBatchCleanupJob.java` at baseline `e818ff11`. `doCalculation(Boolean
isCronJob)`'s only use of the flag: `if (isCronJob && (activation-sysprop-checks)) { continue; }` —
i.e. when `isCronJob` is `false`, the activation-flag check is skipped entirely and cleanup always
runs unconditionally; the flag never affects which tenants are iterated (tenant scope). This matches
"only ever skipped the activation check, never the tenant scope" exactly.

**PASS**.

---

## 8. "`STALE_CLUB_BATCH_CLEANUP_ACTIVATED = false` on all four UAT tenants AND on prd hydra"

**Check attempted:** all configured DB MCP servers (`landlord-dev`, `landlord-uat`, `landlord-prd`,
`wms2-hydra`, `wms2-wineco-dev`, etc.) failed to connect this session
(`CONNECT_TIMEOUT` on every one, per the system reminder at session start). No local `psql` credentials
or `.env` file were available in the worktree/repo to connect directly.

**UNVERIFIABLE** — cannot independently confirm or refute this sysprop-value claim from this session.
Flagging explicitly rather than passing it silently, per instructions. Note the claim is also
self-consistent with the PR's own javadoc, which asserts the same measurement inline
(`StaleClubBatchCleanupJob.java` class doc: "measured 2026-09-02 ... false on every UAT tenant AND on
prd hydra") — that is the same author's claim restated, not independent corroboration.

---

## 9. "UAT confirms the plan's grouping table exactly: all four at 03:00, zones NY/LA two-and-two → two `(cron, zone)` groups"

**UNVERIFIABLE** for the same reason as #8 — requires live UAT tenant sysprop/timezone data, and all
DB MCP servers are unreachable this session.

---

## 10. Design decisions — `TriggerSpec` as its own record with `of(cron, zone)` factory applying the zone-invariant collapse

**Check:** Read `src/main/java/net/aim_ai/wms/schedulejob/TriggerSpec.java` in full (new file, +100
lines). It is `public record TriggerSpec(String cronExpression, String zoneId)` with a static
`of(String cronExpression, ZoneId zone)` factory that calls `isZoneInvariant(cronExpression)` and
substitutes the `ZONE_INVARIANT` sentinel when true. `deriveSpecForCurrentTenant()` in
`StaleClubBatchCleanupJob.java` is the only production call site building via `TriggerSpec.of(...)`,
and both `SchedulingConfiguration.configureStaleClubBatchCleanupGroups` (registration) and
`StaleClubBatchCleanupJob.runFor` (fire-time membership) call that same method — confirmed "the ONE
derivation" claim.

**PASS**.

---

## 11. "The collapse rule is STRICT... would also collapse `0 30 * * * *`... Strict covers exactly `orderRelease`/`replenish` and nothing else"

**Check:** `TriggerSpec.isZoneInvariant` requires fields[1..5] (minute, hour, dom, month, dow) to ALL
equal `"*"` — confirmed strict (only the seconds field, index 0, may be non-`*`). This correctly
rejects `0 30 * * * *` (minute=30, not `*`).

**Note — the "covers exactly `orderRelease`/`replenish` and nothing else" half of this specific
sentence is itself flagged, IN THE CODE'S OWN JAVADOC, as corrected/false**: `TriggerSpec.java`'s
`isZoneInvariant` javadoc has a block headed "⚠ CORRECTED 2026-09-02 (adversarial review): this used
to claim the rule 'covers exactly `orderRelease` and `replenish` and nothing else'. False — it covers
THREE crons today...: `releaseExpiredPickingOrdersFromUser` unconditionally, plus `orderRelease` and
`replenish` only conditionally (while their `*_TIMER_HOUR`/`_MINUTE` sysprops sit at `*`)." The plan
text at line 1415 (which this fact-check was asked to verify) still asserts the old, since-corrected
"exactly orderRelease/replenish" framing — so **that specific clause in the plan document is stale
relative to the shipped code's own javadoc**, though the STRICT-rule mechanics it's describing are
correct.

**Verdict: PASS on "the rule is STRICT and would also collapse `0 30 * * * *`"; FAIL on "covers
exactly `orderRelease`/`replenish` and nothing else"** — the shipped code's own javadoc supersedes
this with a broader, conditional answer (three crons, two of them conditional). This is a real
discrepancy between the plan doc's step-3 text and what actually shipped in the same PR.

---

## 12. Lock key `(100006, tenant_db_configuration.id)` via `pg_try_advisory_lock(int4,int4)`, `Math.toIntExact`, "confirmed live: prd `{2}`, uat `{3,7,13,14}`"

**Check:** `AdvisoryLockService.java` diff (+109 lines): new `tryLock(long jobLockId, long
tenantDbConfigurationId)` / `unlock(long, long)` overloads. Both call `Math.toIntExact(...)` on each id
before binding as `PreparedStatement` `int` params to `SELECT pg_try_advisory_lock(?, ?)` /
`pg_advisory_unlock(?, ?)` (the two-`int4`-arg Postgres form). `JobLockId.STALE_CLUB_BATCH_CLEANUP =
100006L` confirmed unchanged. `StaleClubBatchCleanupJob.runFor` calls only the two-arg
`tryLock(STALE_CLUB_BATCH_CLEANUP, tenantId)` / `unlock(...)` — the one-key `tryLock(100006L)` overload
is no longer called anywhere in this job.

**PASS** on the mechanism (int4,int4 form, `Math.toIntExact`, lock id 100006, one-key form retired for
this job). A `catch (ArithmeticException e)` block in `runFor` logs loudly ("does NOT fit int4 —
CANNOT be locked... skipped every occurrence until the id is fixed") rather than swallowing it,
matching "fails LOUDLY instead of silently colliding."

**UNVERIFIABLE**: "confirmed live: prd `{2}`, uat `{3,7,13,14}`" — same DB-unreachable reason as #8/#9.
The javadoc on `AdvisoryLockService.tryLock(long,long)` states the identical numbers inline, so again
this is the same author's claim restated in two places, not independent corroboration.

---

## 13. "`doCalculation(Boolean)` is DELETED... Those two tests (A7/A8) are rewritten against the two-key lock, not removed"

**Check:** `grep -n "doCalculation" src/main/java/.../StaleClubBatchCleanupJob.java` → zero hits (only
mentioned in the class javadoc's prose describing the removal). Baseline
`StaleClubBatchCleanupJobUnitTest.java` had `@Test ... A7 ...` (line 48) and `@Test ... A8 ...` (line
61). Current file still contains "A7" and "A8" as `@DisplayName` text (line 344: `// ----
rewritten A7 / A8`; line 347: `@DisplayName("activation and error isolation (the rewritten A7/A8
pins)")`; line 351: `@DisplayName("A8′ — activation flag off: lock taken and released...")`).

**PASS** — method is gone from `src/main`, and the A7/A8 test intent is demonstrably carried forward
(renamed/rewritten), not deleted.

---

## 14. "Additive-only is PER SPEC for the grouped job, not per job"

**Check:** `SchedulingConfiguration.onlyIfMissing(reconciling, jobName, configure)` — the five
single-trigger jobs gate on `registrations.containsKey(jobName)` (job name only).
`configureStaleClubBatchCleanupGroups` instead gates each group individually on
`registrations.containsKey(registryKey)` where `registryKey = "staleClubBatchCleanup@" +
spec.cronExpression() + "@" + spec.zoneId()` — i.e. keyed per distinct `TriggerSpec`, not per job name.

**PASS** — the two gating mechanisms are visibly different in the diff, exactly as described.

---

## 15. "The grouped job registers FIRST in `configureAllTasks`... running it first makes that restore load-bearing"

**Check:** `configureAllTasks` body: `configured += configureStaleClubBatchCleanupGroups(...)` is the
first call, followed by five `onlyIfMissing(...)` calls for the other jobs. Javadoc on
`configureStaleClubBatchCleanupGroups` (lines ~807–815) explicitly states the ordering rationale
matches the claim word-for-word in substance: restoring the caller's context makes correctness
order-independent, but running first makes a *dropped* restore detectable (the five reads right after
would fail loudly) versus running last (a dropped restore would hide behind the caller's leftover
context).

**PASS**.

---

## 16. "Rewritten pin, not deleted: `scheduleIsReadUnderTheWinningTenantsContext`"

**Check:** Method exists at line 1155 (baseline `e818ff11`: line 867 of the old path) — same name, both
revisions, confirming rewritten-not-deleted. Read the current body: it now partitions
`syspropReadsByKey` into `singleTriggerReads` (asserted `containsOnly("wh01")` — the probe tenant) and
`groupedReads` (asserted `contains("wh01", "wh09")` — both reachable AND the "unreachable" probe
tenant), with an inline comment explicitly contrasting "Before D′ this asserted `containsOnly("wh01")`
over every read" against the new partitioned behavior. This is an exact match to "the five
single-trigger jobs must still read only under the probe tenant..., and the grouped job must be SEEN
reading under each tenant, including the unreachable one. The pin became a positive AC1 assertion."

**PASS**.

---

## 17. "`NeverMatcherNullBlindnessArchTest` inventory gains `StaleClubBatchCleanupJobUnitTest:2` for two `never().tryLock(eq(JOB), anyLong())` sites"

**Check:** `grep -n "never().*tryLock" StaleClubBatchCleanupJobUnitTest.java` → exactly 2 sites (lines
273, 398), both `verify(advisoryLockService, never()).tryLock(eq(JOB), anyLong())`. A comment at lines
63–64 of that same file states the same fact inline. `git diff` on
`NeverMatcherNullBlindnessArchTest.java` shows exactly one new inventory-map entry added:
`"StaleClubBatchCleanupJobUnitTest:2",` (alphabetically inserted), plus a doc-comment update from
"142... 142 sit on a real primitive" to "144... across 36 classes as of 2026-09-02, not 142."

**PASS** — exact match, both the count (2) and the reason (`tryLock(long,long)` declares primitives,
so `anyLong()` is required, not a style choice).

---

## 18. PIT finding — "A real bug found by a SURVIVING PIT mutant, not by any test" (context-restore bug, fix = restore immediately after the walk)

**Check:** Read `configureStaleClubBatchCleanupGroups` in full. The `try/finally` restoring
`callerContext` is scoped ONLY around the per-tenant walk (lines ~852–887); the `CRON_JOB_SHOW_LOG`
sysprop read and the `register(...)` calls happen AFTER that inner `finally`, i.e. under the restored
caller context — not inside the walk. An inline comment (lines 843–851) states, in the shipped code
itself: "A first version restored only in an outer finally around the whole method, which left the
showLog read unroutable; the tests hid it because a context-blind read returned null and
`Boolean.parseBoolean(null)` is quietly false. PIT found it as a surviving mutant on the additive
gate: with the gate negated the read happened, and no stub could see a read made with no context."
This matches the plan's description of the bug, its cause, and its fix exactly.

**PASS** on the description matching the code and its own comments. I did not independently re-run PIT
to confirm the mutant actually survived pre-fix (no PIT report artifact found in the worktree, and a
from-scratch PIT run was out of this review's time budget) — the claim rests on the shipped code's own
inline account of a real behavior change plus my confirmation that the described defect shape (restore
scoped too broadly, silently-false null read) is a real, plausible bug class that the described fix
(narrow the restore's scope) genuinely closes. Treat "found by PIT specifically, not any other means"
as **UNVERIFIABLE** (no PIT artifact to check), but the underlying bug-and-fix description itself is
corroborated by the diff.

---

## 19. PIT finding — "`members++` → `--` surviving... replaced by the `boolean` the logic actually uses"

**Check:** `StaleClubBatchCleanupJob.runFor` declares `boolean anyMember = false;` (not an `int`
counter), consistent with the claimed refactor from a counter to a boolean. Same caveat as #18: no PIT
report artifact available to independently confirm the described mutant actually survived
pre-refactor.

**PASS** on the code being in the described (boolean, not counter) end state; **UNVERIFIABLE** on the
specific PIT-survival claim for the same reason as #18.

---

## 20. "AC7 arithmetic for this job... at most 1 landlord connection at a time" / "2 holders at 03:00 LA"

**Check:** `runFor`'s per-tenant loop calls `tryLock(...)` then does work then `unlock(...)` in a
`finally`, all within one loop iteration, before moving to the next tenant — i.e. strictly sequential,
never more than one lock/connection held by this job at once, regardless of group size.

**PASS** on "at most 1 landlord connection at a time" for this job specifically.

Confirmed `StockSummaryExportJob.java` is untouched by this PR (`git diff e818ff11 a35cab5a --stat --
.../StockSummaryExportJob.java` is empty) and still calls the one-key
`tryLock(AdvisoryLockService.JobLockId.STOCK_SUMMARY_EXPORT)` — consistent with the "still on the
one-key lock" half of the "2 holders at 03:00 LA" claim.

**UNVERIFIABLE** on the specific "2 holders at 03:00 LA" arithmetic itself — it depends on live UAT/prd
tenant timezone + timer-sysprop data (both jobs' actual trigger times) that requires the unreachable
DB MCP servers to confirm. The code-level precondition (two independent jobs, each capable of holding
at most 1 connection, on genuinely disjoint lock spaces) is verified; whether they actually coincide at
03:00 LA is not independently checked here.

---

## Summary

- **Checked:** 20 distinct claims from the in-scope block (plan lines 1391–1465).
- **PASS:** 16 (PR identity; the full-suite `6216/0` vs `e818ff11` `6173/0` = **+43**, DIRECTLY
  measured on both commits from scratch, not just reconstructed; smallest-job 77 lines; 2
  `doCalculation` sites; zero `JobMetrics` usage; `isCronJob` correction; `TriggerSpec` record/factory;
  STRICT collapse mechanics; lock-key mechanism incl. `Math.toIntExact`/loud failure; `doCalculation`
  deleted + A7/A8 rewritten; per-spec vs per-job additive-only; grouped-job-registers-first ordering
  rationale; rewritten `scheduleIsReadUnderTheWinningTenantsContext` pin;
  `NeverMatcherNullBlindnessArchTest` inventory entry; ≤1 landlord connection per this job).
- **FAIL:** 2 — "the five changed test files" should be **four** (only four of the eight changed test
  files carry a nonzero test-count delta, and those four alone sum to +43 — confirmed both by source
  reconstruction and by the direct full-suite measurement above); and the plan's "Strict covers exactly
  `orderRelease`/`replenish` and nothing else" clause is itself superseded by the shipped code's own
  javadoc, which says three crons (one unconditional, two conditional) — a same-PR internal
  inconsistency between the plan doc and the code's corrected account.
- **UNVERIFIABLE:** 5 — the `STALE_CLUB_BATCH_CLEANUP_ACTIVATED=false` UAT+prd measurement; the UAT
  grouping-table claim; the "confirmed live: prd `{2}`, uat `{3,7,13,14}`" tenant-id set; the
  PIT-specifically-found provenance of the two named mutants (vs. the underlying bug/fix descriptions,
  which ARE corroborated by the diff); and the "2 holders at 03:00 LA" specific coincidence-in-time
  claim — all five blocked by every configured DB MCP server (landlord-dev/uat/prd, wms2-hydra,
  wms2-wineco-dev, etc.) failing to connect this session (`CONNECT_TIMEOUT`), with no local `psql`
  credentials available as a fallback.

**Note on method:** the worktree was temporarily checked out to `e818ff11` to run the baseline suite,
then restored to `a35cab5a` (confirmed via `git rev-parse HEAD`) before finishing this report — no
other worktree or shared state was touched.
