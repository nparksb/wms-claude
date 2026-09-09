# PR #301 fact-check — SBDEV-3198 step 5 part 3 (`OrderReleaseJob` → D′ grouped)

- **PR**: https://github.com/SiteBossInc/wms2-api/pull/301, branch `bugfix/SBDEV-3198-order-release`
- **Commit under test**: `29a64776` "SBDEV-3198 step 5 part 3: convert OrderReleaseJob to D' grouped scheduling"
- **Base**: `bb264b87` (merge of PR #296). `git log --oneline bb264b87..HEAD` → exactly one commit.
- **Worktree**: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-PART3-REVIEW-FACT` (detached at `29a64776`)
- **Date**: 2026-09-03
- **Lane**: independent fact-check (a separate code-review lane ran in `SBDEV-3198-PART3-REVIEW-CODE`)

**Overall verdict: 6 of 6 claims CONFIRMED. One stale test `@DisplayName` is the only defect found (cosmetic, Low).**

---

## Claim 1 — "No dual-lock mitigation needed" — **CONFIRMED**

Both halves of the load-bearing safety argument hold, read directly from the method bodies in
`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-PART3-REVIEW-FACT/src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java`.

### 1a. `releaseOrder()` takes a pessimistic row lock and re-checks state fresh inside it — CONFIRMED

`ReleaseOrderJobService.java:119-137`:

```java
@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW,
        rollbackFor = { BusinessException.class, FacadeException.class })
public Map<Long, Integer> releaseOrder(long orderId, ...) throws FacadeException, BusinessException {
    ...
    Customerorder order = customerorderRepository.findByIdForUpdate(orderId)
            .orElseThrow(() -> new EntityNotFoundException("CustomerOrder", orderId));   // :128
    ...
    if (order.getState() >= WmsConstants.State.ASSIGNED) {                                 // :135
        return itemDataAvailableAmountUpdateMap;                                           // :136
    }
```

The lock is real, not just a method name — `repo/jpa/CustomerorderRepository.java:25-31`:

```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT c FROM Customerorder c WHERE c.id = :id")
@RestResource(exported = false)
Optional<Customerorder> findByIdForUpdate(@Param("id") Long id);
```

The `>= ASSIGNED` re-check at `:135` is downstream of the `findByIdForUpdate` at `:128` and inside the
same `REQUIRES_NEW` transaction, so the row lock is held across the check. A second concurrent caller
blocks on the lock, then reads the already-advanced state and returns an empty map. Exactly as claimed.

### 1b. `releaseDueFutureTransferOrders()` is a self-excluding bulk UPDATE — CONFIRMED

`ReleaseOrderJobService.java:823-838` delegates to two `@Modifying` bulk updates, both with an exact
state predicate that the update itself invalidates:

`repo/jpa/CustomerorderRepository.java:228-231`
```java
@Modifying
@Query("UPDATE Customerorder co SET co.state = :raw, co.modified = CURRENT_TIMESTAMP "
     + "WHERE co.state = :futurePickingDate AND co.pickingdate <= :today "
     + "AND co.orderbatchId IN (SELECT b.id FROM CustomerorderBatch b WHERE b.type IN :types)")
```

`repo/jpa/CustomerorderPositionRepository.java:123-127`
```java
@Modifying
@Query("UPDATE CustomerorderPosition cp SET cp.state = :raw WHERE cp.state = :futurePickingDate ...")
```

`state = FUTURE_PICKING_DATE → RAW` under a `WHERE state = FUTURE_PICKING_DATE` predicate: a second
concurrent execution matches zero rows. Naturally idempotent, as claimed.

### 1c. Sibling lock shapes — the comparison the claim rests on is accurate

`grep -n "tryLock(\|unlock(" src/main/java/net/aim_ai/wms/schedulejob/<Job>.java`:

| Job | one-key `tryLock(id)` | two-key `tryLock(id, tenantId)` | dual-lock? |
|---|---|---|---|
| `CleanUpOldMessagesJob` (step 5 pt 1) | `:207` | `:220`, `:343` | **yes** |
| `StockSummaryExportJob` (step 4) | `:266` | `:280`, `:395` | **yes** |
| `StaleClubBatchCleanupJob` (step 3) | — | `:190` | no |
| `ReleaseExpiredPickingOrdersFromUserJob` (step 5 pt 2) | — | `:189`, `:291` | no |
| `OrderReleaseJob` (this PR) | — | `:210`, `:303` | no |

So "unlike `CleanUpOldMessagesJob`… the same shape `StaleClubBatchCleanupJob` uses" is literally correct.
(The PR does not mention that step 4's `StockSummaryExportJob` also carries the dual-lock. Not a false
statement — just an omission from the comparison set.)

### 1d. Note — a third write path the PR's enumeration omits, and it is also safe

The job also calls `releaseOrderJobService.markClientHasNoSection(...)` (`OrderReleaseJob.java:414`).
The PR's "this job's write path is self-protecting" enumeration names only the two above. Checked
anyway: `CustomerorderRepository.java:201-202` is
`UPDATE ... SET co.state = :noSection WHERE co.id = :id AND co.state IN (:raw, :futurePickingDate)` —
the same self-excluding conditional-bulk-update shape, returning 0 on a repeat. The conclusion is
unaffected; the enumeration was merely incomplete, not wrong.

---

## Claim 2 — "The activation check was inside the ONE shared per-tenant loop both paths used" — **CONFIRMED**

Pre-D′ source located as follows:

```
$ git log --oneline --follow -- src/main/java/net/aim_ai/wms/schedulejob/OrderReleaseJob.java | head -3
29a64776 SBDEV-3198 step 5 part 3: convert OrderReleaseJob to D' grouped scheduling
e83d9550 SBDEV-3198 AC13(b): "run now" means the caller's tenant, not every tenant
6681b448 SBDEV-2945: transfers honor future picking dates and allow date changes

$ git merge-base --is-ancestor e83d9550 bb264b87 && echo ancestor
ancestor
```

so the pre-D′ file is `git show bb264b87:src/main/java/net/aim_ai/wms/schedulejob/OrderReleaseJob.java`
(381 lines). Reading `doCalculation(Boolean isCronJob)` there:

**(a) The activation check really existed** — old lines 122-127:

```java
if (!Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY))
    || !Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_ORDER_TIMER_ACTIVATED_KEY))) {
    LOG.info("orderReleaseJob not activated for {} - {}", ...);
    jobMetrics.tenantSkippedNotActivated(tenantName);
    continue;
}
```

Both flags, in that order. Matches the PR's naming exactly.

**(b) It really was inside a loop shared by BOTH paths** — the loop is a single
`for (TenantProfile tenantProfile : tenantProfiles)` at old line **114**, and `tenantProfiles` is
assigned by an if/else *above* it that covers both paths:

```java
final boolean scheduled = Boolean.TRUE.equals(isCronJob);          // old :78
...
List<TenantProfile> tenantProfiles;
if (scheduled) {
    tenantProfiles = tenantDbConfigurationRepository.findByActiveTrue()...toList();   // old :93-100
} else {
    // Exactly one tenant, so the loop below is unchanged.
    tenantProfiles = List.of(callerTenant);                                            // old :106-110
}

boolean anyFailure = false;
for (TenantProfile tenantProfile : tenantProfiles) {                                   // old :114
    ...
    if (!Boolean.parseBoolean(... NEW_CRON_JOB_ACTIVATED ...) || !... ORDER_TIMER_ACTIVATED ...) {
        continue;                                                                      // old :122-127
    }
    releaseOrders(tenantName);                                                         // old :129
```

There is exactly one loop and exactly one activation check in the whole method. The manual path
(`isCronJob=false`) was **not** activation-flag-free — it went through the same gate. This is the
opposite of the PR #293 situation that produced the shipped bug fixed in #296, and the PR's caution
here is correct.

**Preservation in the new code** — both new entry points carry the same two-flag check in the same order:
- `OrderReleaseJob.java:216-222` (inside `runFor`, per matched tenant, under that tenant's two-key lock)
- `OrderReleaseJob.java:308-313` (inside `runForCurrentTenant`, under the caller's two-key lock)

---

## Claim 3 — Trigger-count arithmetic in `SchedulingConfigurationUnitTest.GroupedRegistration` — **CONFIRMED (numbers); one stale `@DisplayName`**

Fixture facts, read from the file rather than the comments:

- `EXPECTED_TRIGGER_COUNT = 6` (`SchedulingConfigurationUnitTest.java:86`), "the six jobs `configureAllTasks` registers".
- `SchedulingConfiguration.configureAllTasks` (`:638-645`) registers **4 grouped** jobs
  (`configureStaleClubBatchCleanupGroups`, `configureStockSummaryExportGroups`,
  `configureCleanUpOldMessagesGroups`, `configureOrderReleaseGroups`) + **2 single-trigger**
  (`configureReplenish`, `configureReleaseExpiredPickingOrdersFromUser`).
- The test class stubs `deriveSpecForCurrentTenant()` for exactly those 4 grouped jobs
  (`:171`, `:204`, `:224`, `:244` — the last one added by this PR), each returning cron `0 5 5 * * *`
  in `zoneByFacility`'s zone (default LA).
- `registeredTriggers()` (`:324-329`) is an `ArgumentCaptor` over **all** `scheduler.schedule(...)`
  invocations, i.e. cumulative across boot + reconcile.

### `differentZonesMeanTwoGroups` (`:979`) — asserts `EXPECTED_TRIGGER_COUNT + 4` = **10**

Fixture: 2 tenants, `nywh`→America/New_York, `wsl`→America/Los_Angeles; no gating lists populated.

My count: 4 grouped jobs × 2 distinct zones = 8, + `replenish` 1 + `releaseExpiredPickingOrdersFromUser` 1 = **10**. Assertion `6 + 4 = 10`. **Matches.**

> **Finding (Low, cosmetic).** The `@DisplayName` on this test still reads
> **"…two triggers per grouped job — *nine* in all (AC1/AC2)"** (`SchedulingConfigurationUnitTest.java:978`).
> Nine was correct with 3 grouped jobs (`6 + 3`); with this PR's fourth grouped job it is **ten**. The
> `hasSize` on the next lines was updated `+3 → +4` and the body comment was updated to say "four grouped
> jobs", but the display name was not — `git diff bb264b87..HEAD` shows one `@DisplayName` change in this
> file and it is a different test (`callerContextIsRestored`, "three single-trigger jobs" → "remaining
> single-trigger jobs"). A repo-wide sweep for other stale count prose
> (`grep -n "nine in all\|three grouped\|the three single-trigger"` over
> `SchedulingConfigurationUnitTest.java`, `SchedulingReconcileIdempotencyUnitTest.java`,
> `SchedulingConfiguration.java`) found **this one line and nothing else**, so the PR's "swept stale
> comments throughout the file" is otherwise accurate. Cosmetic only — it is a JUnit display string, not
> an assertion, so nothing is mis-verified by it.

### `noScheduleTenantIsNamed` (`:1135`) — asserts `EXPECTED_TRIGGER_COUNT + 3` = **9**

Fixture: same 2 tenants in different zones, plus `staleClubNoSchedule.add("wsl")`. That list is
consulted **only** in the `staleClubBatchCleanupJob` stub (`:181` — `if (staleClubNoSchedule.contains(facility) || hour == null || hour.isBlank()) return null;`);
the `stockSummaryExport`, `cleanUpOldMessages` and `orderRelease` stubs do not read it.

My count: staleClub loses its LA group → 1; the other three grouped jobs → 2 each = 6; grouped total 7;
+ 2 single = **9**. Assertion `6 + 3 = 9`. **Matches**, and this test moved `+2 → +3` in the diff,
consistent with adding a fourth grouped job that is *not* gated by `staleClubNoSchedule`.

### `tenantAddedAfterBootGetsANewGroupOnReconcile` (`:1157`) — asserts `EXPECTED_TRIGGER_COUNT` then `+ 4`

Fixture: boot with 2 tenants **both** in America/New_York → each of the 4 grouped jobs collapses to one
group → 4 + 2 single = **6**. First assertion `hasSize(EXPECTED_TRIGGER_COUNT)` = 6. **Matches.**

Then a third tenant `ship-c1wh` is added in America/Los_Angeles (`wsl` explicitly held at New_York),
and `reconcileSchedules()` runs. Each of the 4 grouped jobs gains exactly one new LA group; the two
single-trigger jobs' crons are unchanged (the sysprop stub always returns `"5"`, and
`releaseExpiredPickingOrdersFromUser` is hard-coded), so neither re-schedules. Cumulative captured
triggers: 6 + 4 = **10**. Assertion `EXPECTED_TRIGGER_COUNT + 4` = 10. **Matches.**

---

## Claim 4 — `PRIMITIVE_MATCHER_INVENTORY` counts (`AdminTriggerTenantScopeUnitTest` 4→6, `OrderReleaseJobUnitTest` 1→7, total 163→171) — **CONFIRMED**

Counted independently with a script reimplementing the arch test's own two regexes
(`NeverMatcherNullBlindnessArchTest.java:122-123` and `:374-376`) plus comment/string stripping and
paren-balanced span closing — i.e. multi-line `verify(m, never()).x(anyLong(), anyLong());` counts as 2:

```
# at HEAD (29a64776)
AdminTriggerTenantScopeUnitTest.java: never-spans=12 primitive-matchers=6
   line 234 verify(advisoryLockService, never()).tryLock(   ['anyLong()', 'anyLong()']
   line 360 verify(advisoryLockService, never()).tryLock(   ['anyLong()', 'anyLong()']
   line 479 verify(advisoryLockService, never()).tryLock(   ['anyLong()', 'anyLong()']
OrderReleaseJobUnitTest.java:         never-spans=16 primitive-matchers=7
   line 129 verify(advisoryLockService, never()).tryLock(          ['anyLong()', 'anyLong()']
   line 151 verify(releaseOrderJobService, never()).releaseOrder(  ['anyLong()']
   line 233 verify(advisoryLockService2, never()).tryLock(         ['anyLong()', 'anyLong()']
   line 253 verify(advisoryLockService2, never()).tryLock(         ['anyLong()', 'anyLong()']

# at bb264b87 (pre-PR)
AdminTriggerTenantScopeUnitTest.java: never-spans=11 primitive-matchers=4
OrderReleaseJobUnitTest.java:         never-spans=3  primitive-matchers=1
```

4 → **6** and 1 → **7**. Both match the inventory entries `"AdminTriggerTenantScopeUnitTest:6"`
(`:416`) and `"OrderReleaseJobUnitTest:7"` (`:427`).

Running total, summed from the `PRIMITIVE_MATCHER_INVENTORY` literal at each ref:

```
bb264b87: total=163  entries=39
HEAD    : total=171  entries=39
```

**163 → 171 across 39 classes**, exactly as the javadoc at `:405` states. (Note this test is
self-checking — it recomputes `actual` and diffs against the inventory — so the passing full suite is
a second, independent instrument on the same numbers.)

---

## Claim 5 — "Full suite: 6291/0/0/67, matching the known baseline" — **CONFIRMED**

```
$ export SDKMAN_DIR="$HOME/.sdkman"; source "$SDKMAN_DIR/bin/sdkman-init.sh"
$ mvn -o test          # from the SBDEV-3198-PART3-REVIEW-FACT worktree
[WARNING] Tests run: 6291, Failures: 0, Errors: 0, Skipped: 67
[INFO] BUILD SUCCESS
[INFO] Total time:  02:29 min
```

Exact match: **6291 / 0 / 0 / 67**. Zero failures, zero errors.

---

## Claim 6 — PIT mutation-coverage claims — **CONFIRMED (measured, not just reasoned)**

### 6a. `releaseOrders` / `processOrderGroup` have zero diff lines — CONFIRMED

`git diff -U0 bb264b87..HEAD -- .../OrderReleaseJob.java` produces 20 hunks; the **last** is
`@@ -150,3 +256,66 @@`, i.e. nothing at or after old line 152 is touched. `releaseOrders` begins at
old line **156**. Stronger check — byte-comparing the two tails:

```
$ git show bb264b87:.../OrderReleaseJob.java | sed -n '156,381p' > old_tail.java   # 226 lines
$ sed -n '325,550p' src/main/java/net/aim_ai/wms/schedulejob/OrderReleaseJob.java > new_tail.java  # 226 lines
$ diff old_tail.java new_tail.java && echo IDENTICAL
IDENTICAL
```

`releaseOrders(String)` and `processOrderGroup(...)` are **byte-for-byte unchanged**.

### 6b. The `runForCurrentTenant()` boolean-return survivors are equivalent mutants — CONFIRMED

The PR does **not** name line numbers for these survivors, so I could not check the claim as written.
Rather than leave it unverifiable I ran PIT myself — safe here, because this lane has its own worktree
and the concurrent code-review lane is in `SBDEV-3198-PART3-REVIEW-CODE` (no shared Maven state).

```
$ mvn -o org.pitest:pitest-maven:mutationCoverage \
    -DtargetClasses=net.aim_ai.wms.schedulejob.OrderReleaseJob \
    '-DtargetTests=net.aim_ai.wms.unit.schedulejob.*,net.aim_ai.wms.schedulejob.*,net.aim_ai.wms.unit.controller.*'
>> Line Coverage (for mutated classes only): 172/265 (65%)
>> 566 tests examined
>> Generated 115 mutations Killed 61 (53%)
```

Full survivor set (KILLED 61 / NO_COVERAGE 34 / SURVIVED 20):

| Line | Method | Mutator | PR bucket |
|---|---|---|---|
| 228 | `runFor` | MathMutator (long `-` → `+`) | (3) duration-calc arithmetic — `System.currentTimeMillis() - start`, feeds a log line only |
| 255 | `runFor` | MathMutator (long `-` → `+`) | (3) — `System.nanoTime() - startNanos` into `recordDuration` |
| **243** | `runFor` | NegateConditionals | (4) the **named** residual: `if (!anyMember)` |
| **244** | `runFor` | NegateConditionals | (4) the **named** residual: `if (anyReadFailure)` |
| 313 | `runForCurrentTenant` | **BooleanFalseReturnVals** on `return false;` | (2) equivalent |
| 316 | `runForCurrentTenant` | **BooleanTrueReturnVals** on `return true;` | (2) equivalent |
| 319 | `runForCurrentTenant` | **BooleanFalseReturnVals** on `return false;` | (2) equivalent |
| 336, 343, 351, 372, 377 | `releaseOrders` | VoidMethodCall / ConditionalsBoundary / NegateConditionals | (1) unchanged code |
| 363 ×2 | `lambda$releaseOrders$0` | ConditionalsBoundary / NegateConditionals | (1) unchanged code |
| 389, 441 ×2, 544, 546 | `processOrderGroup` | ConditionalsBoundary / NegateConditionals / VoidMethodCall | (1) unchanged code |
| — | `processOrderGroup` | **all 34 NO_COVERAGE** | (1) unchanged code |

Reading the three boolean-return survivors against the source
(`OrderReleaseJob.java:313` `return false;` in the not-activated branch, `:316` `return true;` after
`releaseOrders`, `:319` `return false;` in the catch): each mutator rewrote the return to the value it
already returned, i.e. a byte-identical no-op. **The equivalence claim is correct.**

Two supporting details worth recording, because they cut in opposite directions:

- I initially suspected a contradiction: PIT 1.19.1 ships `EquivalentReturnMutationFilter`
  (feature `FRETEQUIV`, `Feature.named("FRETEQUIV").withOnByDefault(true)` — verified by `javap` on
  `pitest-entry-1.19.1.jar`), registered as a default `MutationInterceptorFactory`, and it explicitly
  targets `BooleanFalseReturnValsMutator` / `BooleanTrueReturnValsMutator`. The repo's `pom.xml`
  declares no `<features>` override. On paper that filter should have removed exactly these mutants.
  **The measurement says otherwise** — it does not reach constant returns inside a multi-branch method —
  so the filter argument is a red herring and the PR is right. Recorded here so the next reviewer does
  not re-derive the same wrong suspicion from the docs.
- The PR's taxonomy is a **completeness** claim ("all remaining survivors are either…"), and every one
  of the 20 survivors lands in one of its four buckets. Note that scope matters: with the narrower
  `-DtargetTests=…OrderReleaseJob*,AdminTriggerTenantScopeUnitTest` there is a 21st survivor —
  `OrderReleaseJob.java:164` `jobMetrics.markLastSuccess()` in the `active.isEmpty()` branch,
  VoidMethodCallMutator — which fits **no** bucket. Widening to the job's full test suite (which is the
  PR's stated scope, "Scoped to `OrderReleaseJob` + its full test suite") kills it, via
  `WholeRunSuccessGaugeUnitTest`. So the claim is true as scoped; it would have been false under a
  narrower reading.

### 6c. Bonus — the named residual is named correctly

The PR calls out "`runFor`'s `if (!anyMember) { if (anyReadFailure) … else … }` log-branch pair
(lines **243-244**)". Measured survivors sit at exactly lines 243 and 244, both
`NegateConditionalsMutator`. The PR's one precisely-cited PIT claim is exact.

---

## Overall verdict

**All six claims CONFIRMED — including the two (dual-lock safety, activation-check history) where a false claim would have shipped a real defect; the only finding is a stale `@DisplayName` reading "nine in all" at `SchedulingConfigurationUnitTest.java:978`, which should read "ten".**
