# SBDEV-3198 step 5 part 4 (`ReplenishOrderJob` → D′) — independent code-correctness review, ROUND 2

- **Repo / branch**: `SiteBossInc/wms2-api`, `bugfix/SBDEV-3198-replenish-order`
- **Worktree**: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-STEP5-PART4`
- **State reviewed**: UNCOMMITTED working tree, fork point `a6c22ac7` (14 modified + 1 new file)
- **Round-1 report**: `sbdocs/1-Projects/wms2/plan/SBDEV-3198-evidence/replenish-review-code.md` (2 High, 5 Medium, 5 Low → FIX FIRST)
- **Lane**: code-correctness, round 2 (re-verification by hand-mutation, not by trusting the fix)
- **Date**: 2026-09-04

**Verdict: FIX FIRST** — 0 High, 3 Medium (all NEW), 5 Low (all NEW), 2 Info.

**All 12 round-1 findings: 11 genuinely closed, 1 (M-1) substantively delivered but its stated
mutant kill does not exist.** No production-code defect found in round 1 or round 2; the D′
wrapper's locking and refusal ladder is now fully mutation-pinned. Every remaining finding is a
**claim-accuracy** problem — three of them are *false statements introduced by the round-1 fix pass
itself*, two of which PIT contradicts directly. That is precisely the failure mode this ticket's
review history exists to catch, so it should not ship uncorrected; the corrective pass is ~30
minutes and changes **no production behaviour** (two test assertions + six comment/javadoc edits).

---

## 0. Verification performed (instruments, not claims)

| Check | Instrument | Result |
|---|---|---|
| Full suite | `mvn clean test` | **6305 run / 0 failures / 0 errors / 67 skipped — BUILD SUCCESS.** Reproduces the stated figure exactly. |
| Type safety | same (full `src/main` + `src/test` javac of all 15 touched files) | clean. `lsp_diagnostics` unavailable — `jdtls` is not installed in this environment; a full compile of every changed file plus 6305 green tests is the stronger substitute and is what was used. |
| PIT, as round 1 scoped it | `org.pitest:pitest-maven:mutationCoverage`, `targetClasses=ReplenishOrderJob,SchedulingConfiguration,AdminActionController`, the 10 named test classes | **394 mutations, 299 killed, 66 survived, 29 no-coverage → 82% test strength.** vs round 1's 288/65/41. Mutation coverage 73% → **76%**. |
| PIT, wrapper-scoped (the L-4 re-measurement) | same run, filtered to `deriveSpecForCurrentTenant`/`runFor`/`runForCurrentTenant`/`replenish` | **76 mutations / 59 killed / 17 survived / 0 NO-COVERAGE / 78% test strength.** Independently reproduces the brief's figure **exactly**. Round-1 wrapper was 74/46/16/**12**/74%. |
| `register()`'s cancel branch really dead? | traced **all 6** `register(...)` call sites in `src/main` | **CLAIM HOLDS** — see §M-5 below. |
| L-5 framing ("adaptation, not a pre-existing bug") | `git show a6c22ac7:…ReplenishOrderJobTest.java` vs working tree | **CLAIM HOLDS** — see §L-5 below. |
| L-1 historical claims about pre-D′ metric behaviour | `git show a6c22ac7:…ReplenishOrderJob.java` | **CLAIM HOLDS** — see §L-1 below. |
| Arch-test count of 19 | hand-counted matcher positions + checked declared param types | **CORRECT** — see §Arch below. |
| Doc sweep completeness | `grep -rniE "not-yet-converted\|unconverted\|remaining (one\|two\|…)\|the two (jobs\|still)\|single-trigger job"` over `schedulejob/` + `AdminActionController` | **3 stale sites MISSED** — see §N-3. |

---

## 1. Round-1 findings — re-verified one by one

### H-1 — `runForCurrentTenant()`'s refusal ladder untested → **CLOSED** ✅

PIT now reports **zero `NO_COVERAGE`** anywhere in `runForCurrentTenant()` (round 1: 12). Every
guard and every non-equivalent return mutant is **KILLED**:

| Line | Refusal path | Guard mutant | Return mutant |
|---|---|---|---|
| `:359`/`:361` | no `TenantContext` | negated conditional **KILLED** | `→true` **KILLED** |
| `:363`/`:366` | **JVM busy** (the one path no sibling has) | negated conditional **KILLED** | `→true` **KILLED** |
| `:372`/`:375` | no landlord row | **KILLED** | `→true` **KILLED** |
| `:379`/`:383` | id overflows int4 | (ArithmeticException path) | `→true` **KILLED** |
| `:385`/`:388` | two-key lock busy | **KILLED** | `→true` **KILLED** |
| `:391-392`/`:395` | not activated (both flags) | **KILLED** ×2 | `→true` **KILLED** |
| `:397`/`:398` | success | `replenish` call removal **KILLED** | `→false` **KILLED** |
| `:401` | `catch (Exception)` | — | `→true` **KILLED** |

The six SURVIVED entries in this method are **all provably equivalent** — verified line by line:
each is `replaced boolean return with false` on a line whose source is literally `return false;`
(`:375`, `:383`, `:388`, `:395`, `:401`) or `replaced boolean return with true` on `:398`'s
`return true;`. A constant replaced by itself is unkillable by construction. This is the same
profile round 1 measured on the merged `OrderReleaseJob` template, so the parity gap is closed.

The new file's JVM-busy test (`refusesWhenJvmBusy`, `ReplenishOrderJobUnitTest:249`) also correctly
asserts the flag is left **`true`** — a refusal that never won the CAS must not clear it. That is
the right assertion and it kills `:363`/`:366`.

### H-2 — `RUNNING.set(false)` and both `unlock`s were surviving removal mutants → **CLOSED** ✅

All four are now **KILLED**:

| Line | Mutation | Round 1 | Round 2 |
|---|---|---|---|
| `:406` | removed `AtomicBoolean::set` (`runForCurrentTenant` finally) | SURVIVED | **KILLED** |
| `:329` | removed `AtomicBoolean::set` (`runFor` finally) | — | **KILLED** |
| `:403` | removed `AdvisoryLockService::unlock` (manual path) | SURVIVED | **KILLED** |
| `:304` | removed `AdvisoryLockService::unlock` (scheduled per-tenant path) | SURVIVED | **KILLED** |

The fleet-wide-wedge hazard round 1 named is now genuinely pinned on both entry points.

### M-1 — no negative D′ group-membership test → **SUBSTANTIVELY DELIVERED, stated kill is FALSE** ⚠️

The two tests exist and are real, well-shaped coverage:
`ReplenishOrderJobUnitTest:101` (`runFor_tenantNotMatchingSpec_…`) genuinely exercises a tenant that
derives `20 0 9 * * *` against a trigger of `20 0 2 * * *`, and asserts no lock attempt, no
per-tenant metric, and that the fire still counts successful. `:131`
(`runFor_tenantDerivationThrows_…`) drives the read-failure path via `timezoneService` throwing.
Both are correct, and the derivation-throws route is the right choice (it is the only call in
`deriveSpecForCurrentTenant` outside the null/blank guard).

**But the in-code comment at `ReplenishOrderJobUnitTest:103-105` claims more than PIT supports:**

> `// Kills the negated-conditional mutants on runFor's` `if (!anyMember) { if (anyReadFailure) ... else ... }` `tail, which had zero coverage (M-1, independent review).`

PIT round 2:

| Line | Source | Round 1 | Round 2 |
|---|---|---|---|
| `:316` | `if (!anyMember)` | SURVIVED | **SURVIVED** |
| `:317` | `if (anyReadFailure)` | NO_COVERAGE | **SURVIVED** |

Coverage improved (NO_COVERAGE → SURVIVED) but **neither mutant is killed**. It cannot be: the only
observable difference between the two branches is *which `LOG.info` fires*, and neither test
captures logs. The comment states a kill that does not exist.

This matters beyond pedantry — the branch distinguishes "this trigger legitimately matched nobody"
from "a tenant was unreadable and may be a silently-dropped member". That distinction is the
operator's only signal for a tenant falling out of every group, and it is still unpinned.

**Fix (small):** this repo already has the machinery — `SchedulingReconcileIdempotencyUnitTest`'s
`messagesAt(Level.INFO)` log capture. Add one assertion per test on the distinguishing substring
(`"matched no active tenant"` vs `"no MATCHING readable tenant"`), which kills both. Failing that,
**correct the comment** to say "gives these mutants coverage; killing them needs a log assertion".

### M-2 — `SchedulingConfiguration`'s boot-probe javadoc stale → **CLOSED** ✅ (but see N-3, N-4)

`SchedulingConfiguration.java:291-310` is rewritten. Every clause round 1 flagged is now correct:
all six jobs converted, no winning-tenant-driven schedule remains, the AC5-provenance sentence is
retired. Internally consistent with the rest of the file's paragraph. Two follow-on issues are
filed separately as **N-3** (the same sweep missed three sibling sites) and **N-4** (it now
contradicts `TriggerSpec`).

### M-3 — `TriggerSpec` javadoc stale in two places → **CLOSED** ✅

Both sites corrected (`TriggerSpec.java:20-26` and the new `:90-97` block). The second correction
also upgrades `replenish`'s zone-invariant collapse from "conditional" to "fires for real", which is
the accurate reading given `REPLENISHMENT_TIMER_HOUR`/`_MINUTE` are `*` on prd hydra and all four
UAT tenants.

### M-4 — two stale counts / an unactioned forward-note → **CLOSED** ✅ (arithmetic query at N-7)

`:1345-1353` FOUR → FIVE with the floor correctly re-derived as "≥5, moves with the grouped-job
count". `:1554-1561` restates the forward-note concretely and correctly records that the
landlord-pool-cap risk is separately accepted (Nam, 2026-09-03). The restated *number* is
internally inconsistent with its own multiplicands — filed as **N-7**, Low.

### M-5 — test name asserted the opposite of what it checked → **CLOSED** ✅, and the new claim **VERIFIED**

Renamed to `noTriggerIsEverCancelledAnyMore` with a matching `@DisplayName`, and the unresolvable
"single remaining caller pinned elsewhere" pointer is gone.

**The replacement comment's load-bearing claim — that `register()`'s cancel-and-reschedule branch
is "DEAD from every src/main call site" — was independently traced and HOLDS.** `register(...)` has
exactly six `src/main` call sites:

- **Five grouped (D′)**: `SchedulingConfiguration:769, 884, 992, 1093, 1270`. Each passes
  `registryKey = jobName + "@" + spec.cronExpression() + "@" + spec.zoneId()`, and `register` stores
  `new Registration(jobName, desired, future)` under that key (`:1497`). So a key hit implies
  `current.spec().equals(desired)` implies the strict no-op at `:1418`. The branch at `:1484` is
  unreachable.
- **One single-trigger**: `:1129`, `releaseExpiredPickingOrdersFromUser`, via the one-arg overload
  (`:1401-1405`). Its cron is the **hard-coded literal `"40 * * * * *"`** (`:1128`) and its zone is
  the `private static final` constant `CRON_SCHEDULE_ZONE` (`:78`). The spec is therefore invariant
  across calls, so a second call also lands on the strict no-op.

Confirmed by PIT: the only non-killed mutant in `register` is a `NO_COVERAGE` return-value mutant,
consistent with a dead branch. The comment's "proposed, not actioned" framing (delete the branch, or
add a direct `register()` test with a synthetic changing key) is the right call to leave open.

### L-1 — two metric behaviours silently disappeared → **CLOSED** ✅, historical claims **VERIFIED**

`ReplenishOrderJob.java:103-116` adds the ⚠ paragraph naming both counters, matching the template's
own treatment. Its two historical claims were checked against the pre-D′ source
(`git show a6c22ac7:…ReplenishOrderJob.java`) and both hold:

- `:111` `RUNNING.compareAndSet` → `:113` `jobMetrics.skippedJvmBusy()`, and `:118`
  `tryLock(JobLockId.REPLENISH_ORDER)` → `:120` `jobMetrics.skippedLockBusy()`, **both before the
  `isCronJob` branch** (`doCalculation(Boolean)` was the single shared entry point at `:90`). So
  "pre-D′ a busy job-wide lock incremented it on EITHER path" and "`RUNNING` was checked once before
  either path branched" are exact.

No contradiction with the earlier paragraph at `:93-101` — the new paragraph explicitly reframes it.

### L-2 — dead one-key `tryLock` stubs → **CLOSED** ✅

`when(advisoryLockService.tryLock(anyLong())).thenReturn(true)` is gone from `ReplenishOrderJobTest`,
`ReplenishOrderJobConnectionBudgetTest` and `ReplenishOrderJobPaginationTest`; the two-key stubs are
correctly kept. The remaining repo-wide hits are other jobs that genuinely still use the one-key
form. `ReplenishOrderJobMetricsUnitTest:201`'s `verify(advisoryLockService, never()).tryLock(anyLong())`
is **not** a leftover stub — it is a deliberate pin that the one-key form is never taken, and is
correct to keep.

### L-3 — per-tenant `TenantContext.clear()` unpinned → **CLOSED** ✅

`:313` `removed call to TenantContext::clear` is now **KILLED** (round 1: SURVIVED).

### L-4 — the mutation-coverage comparison → **RE-MEASURED AND VERIFIED** ✅

Independently reproduced, exactly:

| | round 1 | round 2 |
|---|---|---|
| wrapper mutations | 74 | **76** |
| killed | 46 | **59** |
| survived | 16 | **17** (6 provably equivalent in `runForCurrentTenant`) |
| **no-coverage** | **12** | **0** |
| **test strength** | 74% | **78%** |

`AdminActionController.triggerOrderReplenish` remains at **3 mutations, 3 killed, zero survivors** —
round 1's finding on the combined boolean still holds.

The aggregate 82% figure should still not be carried into the PR description as an
"at-or-above-precedent" claim without the wrapper-scoped table beside it; the honest statement is
"no-coverage eliminated in the changed wrapper, test strength 74% → 78%".

### L-5 — `setId(…)` framing → **VERIFIED, the corrected framing is right** ✅

`git show a6c22ac7:…ReplenishOrderJobTest.java` shows `tenant.setId(1L)` / `tenant2.setId(2L)`
already present (`:99`, `:213`, `:237`) but **no `setId` on any `TenantDbConfiguration`**. The
additions are exactly `tenantDbConfig.setId(1L)` (`:119`) and `tenantDbConfig2.setId(2L)`
(`:245`, `:270`) — i.e. on the object whose `getId()` only the new two-key lock reads (`runFor:272`).
Pre-D′ `doCalculation` never read `config.getId()`. **"Required adaptation, not a pre-existing
fixture bug" is the correct characterisation.**

---

## 2. NEW findings

### N-1 — a test's NAME and comment claim a mutant kill that PIT contradicts (`stopTenantTimer`)
**Severity: Medium · Confidence: High · NEW**
**File**: `src/test/java/net/aim_ai/wms/unit/schedulejob/ReplenishOrderJobUnitTest.java:157-161`

The test is named `runFor_tenantMatchesButNotActivated_stillUnlocksAndClearsContextAndStopsTimer`
and its comment states:

> `// Closes three removal-mutant survivors PIT found with zero coverage before this test:`
> `// AdvisoryLockService::unlock … (:289), JobMetrics::stopTenantTimer in the outer per-tenant finally (:297), and`
> `// TenantContext::clear in that same finally (:298, also L-3).`

PIT round 2, on exactly those three:

| Line (current) | Mutation | Status |
|---|---|---|
| `:304` | removed `AdvisoryLockService::unlock` | **KILLED** ✅ |
| `:313` | removed `TenantContext::clear` | **KILLED** ✅ |
| **`:312`** | **removed `JobMetrics::stopTenantTimer`** | **SURVIVED** ❌ |

Two of three closed; the third did not. The test uses a **real** `JobMetrics` (so the line executes,
which is why it moved NO_COVERAGE → SURVIVED) but asserts **nothing** against the registry — so
deleting `jobMetrics.stopTenantTimer(...)` is invisible to it. The `…AndStopsTimer` suffix in the
method name is doing the same harm round-1 M-5 was raised about: a future reader greps the name,
believes the per-tenant timer is pinned, and it is not.

**Compounding, on the same code path**: `:295` `removed call to JobMetrics::tenantSkippedNotActivated`
also **SURVIVED**. This test walks that exact branch, with a real registry, and asserts nothing on
that counter either.

**Fix** — two lines in that test close both (the fixture's `jobSegment` is `"replenish_test"`, and
`JobMetrics:44`/`:88` give the meter names):

```java
assertThat(registry.counter("wms2.cron.replenish_test.skipped_not_activated", "tenant", "acme").count())
        .isEqualTo(1.0);                                                        // kills :295
assertThat(registry.timer("wms2.cron.replenish_test.tenant_duration", "tenant", "acme").count())
        .isEqualTo(1L);                                                         // kills :312
```

If the assertions are not added, **rename the test** to drop `AndStopsTimer` and correct the comment
to list two closures, not three.

### N-2 — the M-1 tests' comment claims a kill on `runFor`'s `!anyMember`/`anyReadFailure` tail that did not happen
**Severity: Medium · Confidence: High · NEW**
**File**: `ReplenishOrderJobUnitTest.java:102-105`; `ReplenishOrderJob.java:316-317`

Full detail under §M-1 above. Summary: both negated-conditional mutants **SURVIVED**; the comment
says "Kills". Fix = one log assertion per test, or correct the comment.

### N-3 — the M-2/M-3 doc sweep missed three sibling sites of the *same* stale-count class
**Severity: Medium · Confidence: High · NEW**

M-2 exists because this exact paragraph had gone stale three times. The corrective sweep fixed the
paragraphs round 1 named and stopped there. Three more sites, two of them **within 180 lines of an
edited paragraph in the same file**, are now false:

1. **`SchedulingConfiguration.java:118-120`**
   > `// LIVE for grouped jobs and forward-looking for the two still on CRON_SCHEDULE_ZONE`
   > `// (replenish, releaseExpiredPickingOrdersFromUser — N-1, PR #301 round-2 review).`

   `replenish` no longer registers on `CRON_SCHEDULE_ZONE` — `configureReplenishGroups:990` builds
   the key from `spec.zoneId()`, the tenant's own resolved zone. **One** job remains, not two. This
   is the identical defect M-3 fixed in `TriggerSpec`, in the file M-2 was raised against.

2. **`SchedulingConfiguration.java:123-125`**
   > `Keyed in {@link #registrations} by {@code jobName} for the two single-trigger jobs and by`
   > `{@code jobName + "@" + cronExpression + "@" + zoneId} for grouped ones`

   `replenish` was one of "the two". There is now exactly **one** single-trigger job. (The same
   plural recurs harmlessly at `:1679`, where it reads as generic phrasing — Info, not a count.)

3. **`ReleaseExpiredPickingOrdersFromUserJob.java:66-67`**
   > `This is the first of the three single-trigger jobs (with {@code OrderReleaseJob} and`
   > `{@code ReplenishOrderJob}, step 5 parts 3-4) to convert, and sets their template.`

   Both named jobs went **GROUPED (D′)**, not single-trigger — parts 3 and 4 took the Option B fork.
   This sentence **directly contradicts `ReplenishOrderJob`'s own class javadoc** (`:29-33`:
   *"Converted to the GROUPED D′ shape … mirroring `OrderReleaseJob`/`CleanUpOldMessagesJob` rather
   than part 2's minimal single-trigger shape"*). It was half-wrong after part 3 and is fully wrong
   after part 4; "sets their template" is the load-bearing false clause, since neither job used this
   one as its template.

**Fix**: one pass, three edits. Worth also re-running the sweep grep before the PR — the pattern
that found these is in §0.

### N-4 — `TriggerSpec` and `SchedulingConfiguration` now contradict each other on the word "unconverted"
**Severity: Low · Confidence: High · NEW**

- `TriggerSpec.java:20-21` (M-3 fix): *"the one-arg `register` overload used by the **ONE remaining
  unconverted job**, `releaseExpiredPickingOrdersFromUser`"*
- `SchedulingConfiguration.java:291-296` (M-2 fix): *"**No unconverted job remains.** … all SIX jobs
  are converted (… `releaseExpiredPickingOrdersFromUser`, …)"*

Same word, same job, opposite verdicts, landed in the same pass. Both are defensible under different
senses — "converted to D′ grouped shape" (5 jobs) vs "converted off winning-tenant sysprop
scheduling" (6, since #6 never was sysprop-driven) — but neither says which sense it means, and a
reader hitting both concludes one is stale. Given M-2's whole history is readers trusting a stale
count, pick one vocabulary. Suggest: reserve "converted" for the D′ conversion (5 grouped + 1
single-trigger), and phrase `SchedulingConfiguration` as *"no job's schedule is driven by a winning
tenant any more"* — which is the true, load-bearing statement it actually needs.

### N-5 — the new test file's nested-class javadoc invents a test that does not exist
**Severity: Low · Confidence: High · NEW**
**File**: `ReplenishOrderJobUnitTest.java:198-200`

> `{@code AdminTriggerTenantScopeUnitTest.Replenish} only exercises the no-context refusal, **the
> JVM-busy-at-entry refusal**, and the happy path.`

`AdminTriggerTenantScopeUnitTest.Replenish` has four tests —
`adminTrigger_runsOnlyTheCallersTenant`, `adminTrigger_withNoTenantContext_doesNothing`,
`adminTrigger_leavesTheCallersContextIntact`, `cronRun_stillLoopsEveryActiveTenant` — and **none is
a JVM-busy test.** The confusion is understandable: `adminTrigger_withNoTenantContext_doesNothing`
does assert `replenishRunningFlag()` is false, but that is the *no-context* refusal, where the CAS
never ran — which is exactly the distinction round-1 H-2 drew. Round 1's own text is the correct
inventory: *"the only manual-path tests … are `AdminTriggerTenantScopeUnitTest.Replenish`'s three:
happy path, no-`TenantContext`, and context-intact."*

The claim is self-undermining: it asserts the template already covers the one case this file was
written to add. **Fix**: drop the middle clause.

### N-6 — arch-test inventory javadoc says "two top-level tests"; the file has three
**Severity: Low · Confidence: High · NEW**
**File**: `NeverMatcherNullBlindnessArchTest.java:412`

> `{@code ReplenishOrderJobUnitTest:19} (its {@code RunForCurrentTenantLocking} nested class plus
> **two top-level tests** …)`

`grep -c "^    @Test"` → **3**. The **count of 19 is correct** (see §Arch), so this is narrative
drift only — but in a class whose entire purpose is an exact, hand-maintained inventory, the
narrative is the thing a future maintainer re-derives from. Likely origin: only two of the three
top-level tests contribute `tryLock` sites; the third contributes a `cancelReplenishmentOrder` site.

### N-7 — M-4's restated arithmetic does not follow from its own multiplicands
**Severity: Low · Confidence: High · NEW**
**File**: `SchedulingConfiguration.java:1556-1559`

> `Five grouped walks × every cached tenant (4 on UAT) × 2 sysprop reads + 1 zone lookup per tenant,`
> `every reconcile cycle (every 5 minutes) — **up to 20 tenant-DB queries per cycle** from`
> `registration walks alone`

5 × 4 = **20 tenant-context visits**; each costs 2 sysprop reads + 1 zone lookup, so the query count
is up to **60**, not 20 (or 40 if the zone lookup is not a tenant-DB query). The stated number is
the visit count wearing the label of the query count. Since the paragraph's stated purpose is *"so
the number is on record"*, the number should be the right one — or the unit should be relabelled
"tenant-pool touches". (Two further caveats worth a clause: not every grouped job reads exactly two
sysprops, and `SyspropService`/`TimezoneService` are `@Cacheable`, so the DB-query figure is an
upper bound on a cold cache, not a steady-state rate.) Does not change the accepted-risk decision.

### N-8 — the re-asserted "LOAD-BEARING restore" claim is not pinned by any test, and `replenish` is now the walk it depends on
**Severity: Low · Confidence: High · NEW**
**File**: `SchedulingConfiguration.java:638-645`

The M-2/M-4 sweep rewrote and re-asserted this comment:

> `// running them first makes that restore LOAD-BEARING — if it were dropped, the single`
> `// single-trigger read below would run with no context and refuse`

`configureReplenishGroups` is now the **last** grouped walk before
`configureReleaseExpiredPickingOrdersFromUser`, so by the comment's own logic *its* restore is the
one that matters. PIT: removing `configureReplenishGroups`'s `TenantContext::clear` (`:959`), its
`if (callerContext != null)` guard (`:963`) and its `TenantContext.setCurrentTenant(callerContext)`
restore (`:964`) **all SURVIVE**. The reason is structural: the "would refuse" behaviour comes from a
real sysprop read routing to a contextless DataSource, and in these tests `syspropService` is a mock
that answers regardless. The property is real in production and unobservable in the suite.

This is **pre-existing across all five grouped methods** (identical survivor shape on
`configureStockSummaryExportGroups` and `configureCleanUpOldMessagesGroups`), so it is not a
regression this PR introduced — but the PR re-asserted the sentence, and the job it now depends on
is the one this PR added. Either soften the claim to "load-bearing in production; not observable in
the unit suite, which mocks `syspropService`", or pin it with a test whose `syspropService` stub
throws when `TenantContext` is null.

---

## 3. Info

- **I-1 — `configureReplenishGroups` mutation profile is at precedent parity, 3 weaker than its
  stated template.** 24 mutations / 16 killed / 7 survived / 1 no-coverage — **byte-identical
  survivor shape** to `configureStockSummaryExportGroups` and `configureCleanUpOldMessagesGroups`.
  `configureOrderReleaseGroups`, which the javadoc says it "mirrors exactly", has 4 survivors: it
  additionally kills the three negated-conditionals on
  `if (groups.isEmpty() && !reconciling && !alreadyRegistered)` (`:1005`), i.e. the
  *"cron schedule not configured for any tenant — task not registered"* error branch is pinned for
  `orderRelease` and unpinned for `replenish`. Structurally the mirror claim is true; the coverage
  claim is not stated, so this is not a finding — just the cheapest remaining win if more strength
  is wanted.
- **I-2 — typo**, `SchedulingConfiguration.java:642`: *"the **single single-trigger** read below"*.

---

## 4. Arch-test count of 19 — independently re-derived ✅

Counted by hand, and the declared parameter types were checked rather than inferred from matcher
names (`AdvisoryLockService:179` `tryLock(long, long)`, `:215` `unlock(long, long)`,
`ReplenishOrderJobService:279` `cancelReplenishmentOrder(long)` — **all primitive**):

| Matcher site | Count | Positions each | Subtotal |
|---|---|---|---|
| `never()).tryLock(anyLong(), anyLong())` — `:121, :148, :260, :278, :299` | 5 | 2 | **10** |
| `never()).cancelReplenishmentOrder(anyLong())` — `:125, :149, :187, :259, :277, :298, :312, :330, :348` | 9 | 1 | **9** |
| `never()).unlock(JobLockId.REPLENISH_ORDER, 1L)` — `:313` | 1 | 0 (both args are literals, not matchers) | 0 |
| `never()).tenantSuccess/tenantFailure/tenantSkippedNotActivated(any())` — `:122-124` | 3 | 0 (`String` params, not primitive-capable) | 0 |
| | | | **19 ✅** |

Total arithmetic also checks: `AdminTriggerTenantScopeUnitTest` 6→8 (+2, one new two-key site),
`ReplenishOrderJobMetricsUnitTest` 1→3 (+2), new class +19 → 171 + 23 = **194 across 40 classes**.
The arch test is an exact-count assertion and it passes in the green suite, so the list is
self-verifying; the narrative caveat is N-6.

---

## 5. Explicitly checked and found correct

- **New test file, read in full.** No mocking mismatch: `getIdsForUnreachableReplenishOrdersPage`
  is declared `(int state, Pageable)`, so `anyInt(), any()` is right;
  `findItemdataIdsByIdIn(Collection<Long>)` accepts `anyList()`.
- **The `returnsFalseAndStillUnlocksWhenReplenishThrows` reasoning is CORRECT, verified from
  source.** `replenish()` (`:415-463`) calls `replenishorderRepository.findItemdataIdsByIdIn(...)`
  at `:424` **outside any `try`**, so a throw there propagates. Throwing from
  `cancelReplenishmentOrder` would indeed *not* propagate: `cancelUnreachableReplenishment:540-546`
  wraps each row in `catch (OptimisticLock… )` **plus a broader `catch (Exception e)`**. The chosen
  route is the only unwrapped one. Reachability also holds: with `syspropService.getIntValue`
  unstubbed returning `0`, `Math.max(1, 0)` makes `pageLimit = 1`, the stubbed non-empty page yields
  `processedIds = [1L]`, and `:423`'s `!isEmpty()` guard opens. `mergePickingOrders()` and
  `deleteEmptyFixAssignmentWithoutStockToReplenish()` short-circuit on unstubbed sysprops first.
- **Strictness.** `BaseUnitTest` is `@ExtendWith(MockitoExtension.class)` with no override, so
  STRICT_STUBS is already in force for the whole class; the nested `@MockitoSettings` is redundant
  but harmless, and no stub in the file is unused (the suite is green).
- **`doCalculation` is fully retired** — `grep -rn "replenishJob.doCalculation"` over `src/` returns
  nothing. No orphan caller or test.
- **`AdminActionController`** — the combined `orderReleaseRan && replenishRan`, both handler comments
  updated correctly and consistently; PIT still reports zero survivors on the handler.
- **`SchedulingReconcileIdempotencyUnitTest` adaptations** avoid the vacuity trap correctly: both
  `orderRelease` **and** `replenish` are removed from the bare-key loop with an explicit note that
  `afterBoot.get(...)` is already `null` for both and the check would pass as `null == null`. The
  class-javadoc test index was updated for both renames.
- **`ReplenishOrderJobMetricsUnitTest.LockBusy`** was honestly rewritten rather than deleted: it now
  asserts `skipped_lock_busy` is *absent* (the counter L-1 documents as gone) while pinning that the
  whole-run duration timer still fires once — a good encoding of the behaviour change.

## 6. Positive observations

- **The H-1/H-2 fix is the real thing, not a coverage-shaped gesture.** Wrapper NO_COVERAGE went
  12 → 0, and every survivor left in `runForCurrentTenant` is provably equivalent. The
  `refusesWhenJvmBusy` test correctly asserts `RUNNING` stays **true** — the subtle direction, and
  the one a careless port would get backwards.
- **The M-5 dead-branch claim was stated carefully and survives independent tracing of all six call
  sites** — and it was proposed rather than actioned, which is the right call for a T3 ticket.
- **L-5 and L-1 were re-characterised accurately rather than defensively.** Both historical claims
  check out against the pre-D′ source, and L-5's correction ("adaptation, not latent bug") is the
  harder, more honest reading.
- **The arch-test inventory was updated in both directions** (per-class counts *and* total), with the
  boxed-vs-primitive reasoning spelled out — including the correct observation that a no-arg
  `findByActiveTrue()` site adds no primitive-capable position.
- **The M-4 restatement records the accepted-risk decision with its owner and date** and explicitly
  declines to reopen it. That is the right way to close a forward-note.

## 7. Suggested order of work (~30 min, no production-code change)

1. **N-1** — add the two registry assertions (or rename the test + fix its comment).
2. **N-2** — add the two log assertions (or downgrade "Kills" to "covers").
3. **N-3** — three stale-count edits; re-run the §0 sweep grep before the PR.
4. **N-5, N-6** — two one-clause javadoc corrections.
5. **N-4, N-7, N-8, I-2** — vocabulary alignment, the arithmetic number, the softened restore claim,
   the typo.
6. Re-run PIT wrapper-scoped; after N-1 and N-2, expect `:295`, `:312`, `:316`, `:317` to move
   SURVIVED → KILLED, taking wrapper test strength from 78% to ~83%.
