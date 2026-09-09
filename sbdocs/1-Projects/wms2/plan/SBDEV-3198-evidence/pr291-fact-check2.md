---
name: pr291-fact-check2
description: Round-2 independent fact-check of PR #291 (SBDEV-3198 step 5, part 1/4 — CleanUpOldMessagesJob D' conversion) after fix commit 15c6a901
metadata:
  lane: fact-check
  status: reviewed
  base: f440b534323c59d2e80dd6457d711b0b6e1b7bdd (merge-base with origin/develop)
  head: 15c6a901 (bugfix/SBDEV-3198-cleanup-old-messages, PR #291)
  worktree: /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-291-review2-fact
---

# PR #291 round-2 fact-check

Adversarial re-derivation of every checkable, specific claim in the CURRENT PR #291 description
(as of commit `15c6a901`), independent of round-1's own fact-check
(`pr291-fact-check.md`). Scope is quantitative/completeness claims only — code correctness is a
separate lane (`pr291-review2-code.md`).

Toolchain: `export PATH="/home/nampark/.sdkman/candidates/maven/current/bin:/home/nampark/.sdkman/candidates/java/current/bin:$PATH"`; Java 21.0.11, Maven (sdkman current).

## Verdict table

| # | Claim | Verdict | Detail |
|---|---|---|---|
| 1 | Full suite: 6252/0/67 | **PASS** | Independently re-derived, see §1 |
| 2 | "9 test files touched" (corrected from 11) | **PASS** | Confirmed with two instruments, see §2 |
| 3 | NeverMatcher census "148→154 across 37→39" | **PASS** | Manual summation matches exactly at both commits, see §3 |
| 4 | Stale "FOUR single-trigger jobs" comment fixed | **PASS** | No remaining stale reference, see §4 |
| 5 | M-1 fix: real `SimpleMeterRegistry`-backed test, runs green | **PASS** | See §5 |
| 6 | L-1 fix: `startTenantTimer()` first stmt in two-key-lock try | **PASS** | Exact lines quoted, see §6 |
| 7 | L-2 fix: corrected `V2.2.20` framing is an accurate paraphrase | **PASS** | See §7 |
| 8 | L-4 fix: two-tenant test asserts 2.0; javadoc states per-tenant semantics directly | **PASS, with a defect found** | Test and javadoc content are correct, but the javadoc **cites the wrong test method name** — see §8 |
| 9 | M-2 "still open... decision genuinely needs to be made" | **FAIL — PR body is stale/contradicted by the plan doc** | The plan doc records M-2 as **DECIDED 2026-09-03**, risk explicitly accepted by Nam — see §9 |
| 10 | PIT survivors "confirmed pre-existing in ... StockSummaryExportJob at the identical call shape" | **PASS** | `TenantContext::clear()` removal mutant SURVIVED at the equivalent finally-block position in `StockSummaryExportJob.runFor:309`, see §10 |

**8 of 10 fully PASS, 1 PASS-with-a-documentation-defect (§8), 1 FAIL on the framing (§9, not a code defect but a real inconsistency between the PR description and the plan doc).**

---

## §1 — Full suite: 6252/0/67

Ran `mvn -o clean test` in the fact-check worktree (checked out at `15c6a901`), then summed **every**
`target/surefire-reports/*.txt` file independently — not the console tail, not a single file:

```
files: 1679
Tests run: 6252 Failures: 0 Errors: 0 Skipped: 67
```

Exact match to the PR's claimed 6252/0/67. Build itself was `BUILD SUCCESS`.

## §2 — "9 test files touched"

```
git merge-base origin/develop 15c6a901
→ f440b534323c59d2e80dd6457d711b0b6e1b7bdd

git diff --name-status f440b534..15c6a901 -- src/test   → 9 files (all "M")
git diff --stat        f440b534..15c6a901 -- src/test   → 9 files changed, 638(+), 137(-)
```

Both instruments agree: 9. File list:
`SchedulingConfigurationUnitTest.java`, `SchedulingReconcileIdempotencyUnitTest.java`,
`NeverMatcherNullBlindnessArchTest.java`, `AdminActionControllerUnitTest.java`,
`AdminTriggerTenantScopeUnitTest.java`, `CleanUpOldMessagesJobMetricsUnitTest.java`,
`CleanUpOldMessagesJobTest.java`, `CleanUpOldMessagesJobUnitTest.java`,
`WholeRunSuccessGaugeUnitTest.java` — matches the PR body's "Test surgery" section's named list
exactly (the SBDEV-3102 duplicate pair `CleanUpOldMessagesJobTest`/`CleanUpOldMessagesJobUnitTest`
both counted, migrated not consolidated, per the PR's own description).

## §3 — NeverMatcher census "148→154 across 37→39"

`PRIMITIVE_MATCHER_INVENTORY` in `src/test/java/net/aim_ai/wms/unit/config/NeverMatcherNullBlindnessArchTest.java`.

**At HEAD (15c6a901):** extracted all 39 `"ClassName:count"` entries and summed by hand:
```
2+5+8+4+2+2+7+12+1+4+2+1+5+1+1+1+7+2+1+2+5+2+1+12+7+4+2+2+4+5+2+5+4+1+2+3+2+5+16 = 154
```
39 lines, sum 154. Matches the javadoc's own claim at line 391 ("**154** across 39 classes as of
2026-09-03") and the PR body.

**At merge-base (`f440b534`):** `git show f440b534:src/test/.../NeverMatcherNullBlindnessArchTest.java`,
extracted the same inventory list programmatically:
```
wc -l → 37 classes
awk -F: '{s+=$2} END{print s}' → 148
```
37 classes, sum 148. Matches the PR's "148→154 across 37→39" claim exactly, both directions.

Also confirmed the arch test itself is green: `Tests run: 4, Failures: 0, Errors: 0, Skipped: 0` in
`target/surefire-reports/net.aim_ai.wms.unit.config.NeverMatcherNullBlindnessArchTest.txt`.

## §4 — Stale "FOUR single-trigger jobs" comment

`grep -n -i "single-trigger\|\bfour\b" SchedulingReconcileIdempotencyUnitTest.java` — every remaining
"FOUR" in the file is correctly historical/qualified:
- line 224: `// the THREE single-trigger jobs' sysprops are never re-read once registered (was FOUR before ...`
- line 491: `// FOUR new registrations, not five — but no longer "four single-trigger jobs": only ...`
- line 1067: unrelated claim ("four @Scheduled methods in src/main" — a different count, about
  `TenantConfigLoader.scheduledRefresh` / `TenantPoolEvictor.evictIdlePools`, not single-trigger jobs;
  not part of the finding being checked).

All eight "single-trigger" occurrences in the file now correctly say THREE (lines 224, 491-500, 541,
704-819). No stale "FOUR single-trigger jobs" claim remains anywhere in the file. Also checked
`src/main/.../SchedulingConfiguration.java` for the same phrase — all references there already said
"three single-trigger" pre-fix and remain correct.

## §5 — M-1 fix

`CleanUpOldMessagesJobUnitTest.RunForCurrentTenantLocking.doesNotTouchTheWholeRunGauges` (lines
239-254 of `CleanUpOldMessagesJobUnitTest.java`):

```java
private io.micrometer.core.instrument.simple.SimpleMeterRegistry registry;
...
registry = new io.micrometer.core.instrument.simple.SimpleMeterRegistry();
job = new CleanUpOldMessagesJob(..., new net.aim_ai.wms.schedulejob.JobMetrics(registry, "clean_up_old_messages"));
...
void doesNotTouchTheWholeRunGauges() throws Exception {
    ...
    assertThat(registry.get("wms2.cron.clean_up_old_messages.last_run_epoch_seconds").gauge().value()).isZero();
    assertThat(registry.get("wms2.cron.clean_up_old_messages.last_success_epoch_seconds").gauge().value()).isZero();
    assertThat(registry.find("wms2.cron.clean_up_old_messages.skipped_lock_busy").counter()).isNull();
    assertThat(registry.find("wms2.cron.clean_up_old_messages.duration").timer()).isNull();
}
```

Confirmed: real `SimpleMeterRegistry`, not a mocked `JobMetrics` — matches the PR's claim exactly
(`verify(never())` is unavailable against a real registry, so this is the correct assertion style).

Confirmed it actually runs and passes — not just exists — via the surefire XML:
`target/surefire-reports/TEST-...CleanUpOldMessagesJobUnitTest$RunForCurrentTenantLocking.xml`, the
`doesNotTouchTheWholeRunGauges` `<testcase>` has no `<failure>`/`<error>` child, and the class's
`.txt` summary shows `Tests run: 6, Failures: 0, Errors: 0, Skipped: 0`.

## §6 — L-1 fix

`src/main/java/net/aim_ai/wms/schedulejob/CleanUpOldMessagesJob.java`:

```java
214:                    try {
215:                        if (!advisoryLockService.tryLock(AdvisoryLockService.JobLockId.CLEAN_UP_MESSAGES, tenantId)) {
...
219:                        continue;
220:                        try {
227:                            tenantSample = jobMetrics.startTenantTimer();
228:                            long start = System.currentTimeMillis();
...
241:                        } finally {
242:                            advisoryLockService.unlock(AdvisoryLockService.JobLockId.CLEAN_UP_MESSAGES, tenantId);
243:                        }
244:                    } finally {
245:                        advisoryLockService.unlock(AdvisoryLockService.JobLockId.CLEAN_UP_MESSAGES);
246:                    }
```

(Note: the outer `try` at 214 holds the two-key-lock acquisition; the inner `try` at 220 is the one
whose `finally` at 241-243 releases the two-key lock, and `startTenantTimer()` at 227 is its first
statement.) Confirmed exactly as claimed — this matches the L-1 finding's fix.

## §7 — L-2 fix

Class javadoc (`CleanUpOldMessagesJob.java:31-37`) now reads: "...`message_archived` carries NO
primary key (confirmed: `V2.2.20` lists it explicitly as one of six tables without one — and its own
comment there explains why: that table can ALREADY hold duplicate ids from ordinary single-replica
operation, deliberately, because a PK would turn an interrupted archive-then-delete cycle into a
permanently-failing job for that tenant; L-2, PR #291 review)."

Actual `V2.2.20` migration comment (`src/main/resources/db/migration/V2.2.20__authorization_join_table_primary_keys.sql:353-359`):
```
-- * message_archived is NOT given a primary key, despite being one of the six tables without one.
--   MessageRepository.archiveMessages is an UNBOUNDED INSERT-SELECT while deleteMessages is batched
--   in a loop that can exit early - CleanUpOldMessageJobService:99-101 returns on interrupt, and
--   CleanUpOldMessagesJob:90 swallows a per-tenant failure. Either path leaves rows archived but not
--   deleted, so the next run re-archives them: that table can ALREADY hold duplicate ids, silently.
--   A PK on message_archived.id would convert that into a permanently failing archive job on any
--   affected tenant. Different subsystem, different fix.
```

The javadoc's paraphrase is accurate — same claim (already-duplicate-tolerant table, PK would break
interrupted-cycle re-archival), not just an assertion that it's accurate.

## §8 — L-4 fix (defect found: wrong test citation)

Two-tenant test confirmed at `CleanUpOldMessagesJobMetricsUnitTest.java:136-157`
(`tryLockBusy_twoTenantGroup_incrementsSkippedLockBusyPerTenant`), asserting:
```java
assertThat(registry.counter("wms2.cron.clean_up_old_messages.skipped_lock_busy").count()).isEqualTo(2.0);
```
against a genuine two-tenant fixture (`tenantDbConfig` + `tenantDbConfig2`, both busy). Confirmed.

Class javadoc (`CleanUpOldMessagesJob.java:65-73`) does state the per-tenant semantics directly,
not merely by reference to `StockSummaryExportJob`'s javadoc — matches the PR's L-4 claim.

**Defect**: the javadoc's own citation is wrong. It reads (line 70-73):
> `{@code skippedLockBusy}` is recorded once per LOCK-BUSY MEMBER TENANT, not once per group fire...
> Pinned by `{@code CleanUpOldMessagesJobMetricsUnitTest.tryLockBusy_incrementsSkippedLockBusyCounter}`
> against a two-tenant fixture.

`tryLockBusy_incrementsSkippedLockBusyCounter` (lines 116-134) is the pre-existing **single**-tenant
test (`List.of(tenantDbConfig)`, asserts `1.0`). The actual two-tenant test added for L-4 is a
**different, newer method**: `tryLockBusy_twoTenantGroup_incrementsSkippedLockBusyPerTenant`
(lines 136-157). The javadoc cites the wrong method name for the claim it is making — a reader
following the citation lands on the single-tenant test, not the one that actually pins the "2.0, not
1.0" semantics. Minor (documentation-only, doesn't affect test correctness or the suite), but real —
flagging for a follow-up fix.

## §9 — M-2 "still open" claim (PR body contradicted by the plan doc)

Fact 1, confirmed as claimed: `landlord.datasource.maximum-pool-size=2` is still literally `2` in
`src/main/resources/application.properties:66`. No change here — correct.

Fact 2, **not** as claimed: the PR body currently reads (bolded in the PR itself):

> **M-2**: ... **Not a code defect, still open** — DB/actuator MCP access remains unavailable this
> session... **This decision genuinely needs to be made — either read the pool cap, or explicitly
> accept the risk — before parts 2–4 of step 5 add two more dual-form holders.**

But `sbdocs/1-Projects/wms2/plan/SBDEV-3198-per-tenant-cron-scheduling.md:1698-1713` records:

> **M-2 — DECIDED 2026-09-03, risk explicitly accepted, not a code defect.** ... **Nam's decision,
> asked directly given this was the second round in a row the item went unresolved: accept the risk
> and continue, rather than pause step 5 to chase live DB access.** Reasoning recorded: the in-repo
> cap is 2, each dual-lock job briefly needs both connections only during one tenant's critical
> section..., these are nightly off-peak jobs, and the failure mode if the cap genuinely is 2 and two
> jobs' windows overlap is a misleading log message and a skipped occurrence — not data loss or
> corruption. ... **Not a blocker for parts 2–4 going forward** — the live-cap reading remains a
> nice-to-have, not a gate.

This is a direct contradiction, not just a nuance: the plan doc says the decision **was made** on the
same date (2026-09-03) and is **not a blocker**; the PR body says the decision **still needs to be
made** and frames it as an open item before parts 2-4. One of the two documents is stale. Given the
plan doc names Nam explicitly and records reasoning in the first person ("asked directly"), it reads
as the authoritative, later-written record — meaning the **PR description text is what's stale**, not
the plan doc. This matches a prior memory: `sbdev3198-pool-cap-risk-accepted.md` — "Nam 2026-09-03:
not a blocker for step 5 parts 2-4, don't re-raise" — which corroborates the plan doc's version over
the PR body's.

**Verdict: the task's checkable assumption ("confirm the plan doc genuinely records this as an open
decision") does NOT hold — the plan doc records it as CLOSED, contradicting the PR body's "still
open" framing.** Recommend the PR description be corrected before merge so it doesn't misrepresent
the decision status to a future reader who wasn't in the loop.

## §10 — PIT survivor characterization

The PR body claims CleanUpOldMessagesJob's PIT survivors — including `TenantContext.clear()` — are
"confirmed pre-existing in the already-reviewed `StockSummaryExportJob` at the identical call shape."

Ran PIT scoped to `StockSummaryExportJob` alone, against its own test classes:
```
mvn -o org.pitest:pitest-maven:mutationCoverage \
  -DtargetClasses=net.aim_ai.wms.schedulejob.StockSummaryExportJob \
  -DtargetTests='net.aim_ai.wms.unit.schedulejob.StockSummaryExportJob*'
```
`BUILD SUCCESS`, 20 test classes examined, 108 mutations generated, 61 killed (56%; not directly
comparable to CleanUpOldMessagesJob's cited 85% since that ran against 4 self-found-gap-fixed test
classes at higher targeted coverage — this run used the wildcard test-class pattern with no filtering
of pre-existing classes, so the two percentages are not apples-to-apples and the PR does not claim
they are).

Extracted every `SURVIVED` mutation from `target/pit-reports/mutations.xml`. Confirmed:
```
SURVIVED | net.aim_ai.wms.schedulejob.StockSummaryExportJob.runFor:309 | removed call to net/aim_ai/wms/landlord/config/TenantContext::clear
```
at line 309, immediately following a `SURVIVED ... removed call to ... JobMetrics::stopTenantTimer`
at line 308 — the same finally-block position (right after `stopTenantTimer`, inside the per-tenant
loop's outer `finally`) as `CleanUpOldMessagesJob`'s own `TenantContext.clear()` call at line 254
(also immediately after its `stopTenantTimer` call at line 253). Confirmed both source files call
`TenantContext.clear()` at the structurally equivalent point:
```
CleanUpOldMessagesJob.java:253-254   if (tenantSample != null) jobMetrics.stopTenantTimer(...); TenantContext.clear();
StockSummaryExportJob.java:308-309   [stopTenantTimer]; TenantContext.clear();
```

**PASS**: the survivor is real, in the sibling job, at the identical call shape. Other survivors in
`StockSummaryExportJob` (mostly in `exportStockSummary`/`recordOmsVerdict`/lambda setter calls) are
unrelated to `CleanUpOldMessagesJob`'s much simpler logic and not part of the PR's specific claim,
which is scoped to the shared per-tenant-loop shape (timer/lock/TenantContext bookkeeping), not the
whole class's mutation profile.

---

## Reproduction notes

- Merge-base: `git merge-base origin/develop 15c6a901` → `f440b534323c59d2e80dd6457d711b0b6e1b7bdd`
- Full suite: `mvn -o clean test`, then sum every `target/surefire-reports/*.txt` (never trust console
  tail or a single file — 1679 report files this run).
- NeverMatcher inventory: `grep -n "PRIMITIVE_MATCHER_INVENTORY = List.of" -A 45 <file>` then
  `grep -oP '"\K[A-Za-z]+:\d+'`, `wc -l` for class count, `awk -F: '{s+=$2} END{print s}'` for sum.
- PIT: `mvn -o org.pitest:pitest-maven:mutationCoverage -DtargetClasses=<FQCN> -DtargetTests='<pattern>*'`,
  then parse `target/pit-reports/mutations.xml` for `status="SURVIVED"` entries.
