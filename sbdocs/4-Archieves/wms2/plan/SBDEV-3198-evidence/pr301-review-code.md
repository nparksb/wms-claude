# PR #301 — code-correctness review (SBDEV-3198 step 5 part 3, `OrderReleaseJob` → D′)

- **Repo / branch**: `SiteBossInc/wms2-api`, `bugfix/SBDEV-3198-order-release`
- **Commit reviewed**: `29a64776` ("SBDEV-3198 step 5 part 3: convert OrderReleaseJob to D' grouped scheduling")
- **Base**: `bb264b87` (last merged), pre-D′ source read at `e83d9550`
- **Worktree**: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-PART3-REVIEW-CODE` (detached)
- **Reviewer lane**: code-correctness, round 1
- **Date**: 2026-09-03

---

## 0. Verification performed

| Check | Instrument | Result |
|---|---|---|
| Targeted test run | `mvn -o test -Dtest='OrderReleaseJob*,SchedulingConfigurationUnitTest,SchedulingReconcileIdempotencyUnitTest,AdminTriggerTenantScopeUnitTest,AdminActionControllerUnitTest,WholeRunSuccessGaugeUnitTest,NeverMatcherNullBlindnessArchTest'` | **159 run, 0 failures, 0 errors, 2 skipped — BUILD SUCCESS** |
| Business logic unchanged | `diff` of `releaseOrders(String)` + `processOrderGroup(...)` extracted from `e83d9550` vs HEAD | **byte-identical** |
| `runFor`/`runForCurrentTenant` vs merged sibling | normalized `diff` against `bb264b87:CleanUpOldMessagesJob.java` | identical modulo the deliberate absence of the one-key/dual-lock + its `skippedLockBusy()` |
| `configureOrderReleaseGroups` vs `configureCleanUpOldMessagesGroups` | normalized `diff` of the two method bodies | **identical except the log string and the javadoc** |
| Activation-check provenance claim | `git show e83d9550:…/OrderReleaseJob.java` | **confirmed** — see §1 |
| "no dual-lock needed" claim | read `ReleaseOrderJobService.java:121-135`, `:824-831` independently of the javadoc | **confirmed** — see §2 |
| `NeverMatcherNullBlindnessArchTest` counts | counted `anyLong()/anyInt()/anyBoolean()` inside `never()` verifies by hand in both files | **6 and 7 — both correct**; inventory sums to **171 across 39 classes**, matching the javadoc |
| Trigger-count arithmetic | re-derived each `EXPECTED_TRIGGER_COUNT + N` from the fixture | **all correct** — see §5 |

---

## 1. Activation check — claim verified, both paths correct

The commit message and class javadoc claim the activation check was confirmed *directly from the pre-D′ source* rather than assumed from a sibling (the PR #293 / step 5 part 2 lesson). **This checks out.**

`git show e83d9550:src/main/java/net/aim_ai/wms/schedulejob/OrderReleaseJob.java` shows `doCalculation(Boolean isCronJob)` building `tenantProfiles` from either `findByActiveTrue()` (scheduled) or `List.of(callerTenant)` (manual) and then running **one shared loop** over it. Inside that single loop, before any work:

```java
if (!Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY))
    || !Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_ORDER_TIMER_ACTIVATED_KEY))) {
```

So the gate genuinely applied to the manual path too. The PR preserves it in both replacements, same two keys, same order:

- `OrderReleaseJob.java:218-224` — `runFor`, inside the two-key lock, before `releaseOrders(tenantName)`, with `jobMetrics.tenantSkippedNotActivated(tenantName)`.
- `OrderReleaseJob.java:309-314` — `runForCurrentTenant()`, inside the two-key lock, before `releaseOrders(...)`, `return false`, **no** metric (correct per the family's M-2/N-3 rule).

Coverage exists on **both** paths, which is what PR #293's regression lacked:

- scheduled: `OrderReleaseJobTest.java:139` `shouldSkipWhenJobNotActivated`, `:155` `shouldSkipWhenOrderTimerNotActivated`, `:198` `shouldNotReleaseDueFutureTransfersWhenNotActivated`, plus `OrderReleaseJobMetricsUnitTest.java:250` `sysPropDeactivated_incrementsSkippedNotActivated`.
- manual: `OrderReleaseJobUnitTest.java:282` `refusesWhenNotActivated` and `:300` `refusesWhenGlobalCronSwitchOff` (the latter stubs the second flag `lenient()`ly so a deleted-`||` mutant dies on the assertion rather than on a `PotentialStubbingProblem` — correct).

**No finding.**

## 2. "No dual-lock needed" — claim verified independently

Checked against the source, not the javadoc:

- `ReleaseOrderJobService.java:121` `releaseOrder(long orderId, …)` is `@Transactional(REQUIRES_NEW)`; `:128` `customerorderRepository.findByIdForUpdate(orderId).orElseThrow(...)` is the pessimistic `SELECT … FOR UPDATE`; `:135` `if (order.getState() >= WmsConstants.State.ASSIGNED)` re-reads the state **inside** that lock. A racing old-code whole-fleet caller blocks on the row lock and then no-ops. ✔
- `ReleaseOrderJobService.java:824` `releaseDueFutureTransferOrders()` is a bulk `customerorderRepository.releaseDueFutureTransferOrders(...)` update — self-excluding, idempotent. ✔

So `AdvisoryLockService.JobLockId.ORDER_RELEASE` taken **only** in the two-key `(id, tenantId)` form is the right call, matching `StaleClubBatchCleanupJob` (`:190`/`:208`) and `ReleaseExpiredPickingOrdersFromUserJob` (`:189`/`:214`), neither of which takes a one-key lock either.

Lock symmetry is correct on both paths — `OrderReleaseJob.java:210` `tryLock(…, tenantId)` / `:231` `unlock(…, tenantId)` in a `finally`, and `:303` / `:321` likewise. The `continue` at `:223` (not-activated) exits through that `finally`, so the lock is released. `Math.toIntExact` guards precede the lock on both paths (`:201`, `:297`). `TenantContext` is set at `:183` and cleared in the per-tenant `finally` at `:240`; `runForCurrentTenant()` never touches `TenantContext` at all, which is what lets `AdminActionController` call `replenishJob.doCalculation(false)` next with the caller's context intact — pinned by `AdminTriggerTenantScopeUnitTest.adminTrigger_leavesTheCallersContextIntact`.

`JobMetrics` split is implemented as claimed, not just asserted: `runFor` touches `markLastRun`/`recordDuration`/`markLastSuccess` (`:252-255`) plus `tenantSuccess`/`tenantFailure`/`tenantSkippedNotActivated`/`startTenantTimer`/`stopTenantTimer`; `runForCurrentTenant()` touches none of them, verified both by reading and by `OrderReleaseJobUnitTest.doesNotTouchTheWholeRunGauges` reading a real `SimpleMeterRegistry`.

**No finding.**

---

## Findings

### High

*None.*

---

### Medium

#### M-1 — `TriggerSpec`'s "NOT-YET-REACHABLE" label is now false, and the zone-invariant collapse goes live on prd with this merge

`src/main/java/net/aim_ai/wms/schedulejob/TriggerSpec.java:74-78`:

> `⚠ Also NOT-YET-REACHABLE (§6a.6's labelling standard): the only job routed through {@link #of(String, ZoneId)} today is {@code staleClubBatchCleanup} … so this collapse cannot fire in production until {@code orderRelease} or {@code replenish} convert (plan §7a step 5). Do not read it as live behaviour yet.`

**This PR is the exact event that comment names as its own expiry condition, and it was not updated.** The same file (`:66-70`) records the measurement: on prd hydra and all four UAT tenants `ORDER_TIMER_HOUR`/`_MINUTE` both sit at the `*` default. `deriveSpecForCurrentTenant()` (`OrderReleaseJob.java:147`) therefore builds `"0 * * * * *"`, all five non-second fields are `*`, `isZoneInvariant` returns true, and the spec's `zoneId` becomes `ZONE_INVARIANT`.

**Mechanically this is sound** — I checked the consumer: `register(...)` at `SchedulingConfiguration.java:1366` uses `desired.zoneForTrigger()`, and `TriggerSpec.java:101-103` maps `ZONE_INVARIANT` to `ZoneId.of("UTC")`; and because registration (`configureOrderReleaseGroups`) and fire-time membership (`runFor`) both go through the *same* `deriveSpecForCurrentTenant()`, no tenant can silently fall out of its group. So this is **not a functional bug**. But two written claims stop being true on merge:

1. The `NOT-YET-REACHABLE` label above.
2. `SchedulingConfiguration.java:797-798` — *"Every tenant now gets its own group, exactly as this job's schedule sysprops always allowed."* On today's prd config **every tenant lands in the same single group** `orderRelease@0 * * * * *@zone-invariant`, because they all agree on `*`/`*`. The per-tenant benefit this conversion unlocks is real but **latent** — it materialises only when an operator sets a tenant-specific hour/minute. The §1.2-closure framing overstates what changes on prd on day one, and the next reviewer reading these two comments together will get a wrong mental model of the deployed state.

**Recommendation:** update `TriggerSpec.java:74-78` to say the collapse is live for `orderRelease` as of this PR (naming the prd `*`/`*` config that makes it so), and soften `SchedulingConfiguration.java:797-798` to "each tenant now derives its own spec; tenants that agree share one group — on prd today that is a single group for the whole fleet."

#### M-2 — `orderRelease` loses its only lock-contention metric, and the test that appears to guard it is now vacuous

Pre-D′ (`e83d9550`), a busy lock incremented `jobMetrics.skippedLockBusy()`. After this PR, `grep -rn "skippedLockBusy" src/` returns **zero hits in `OrderReleaseJob.java`** — neither path records it:

- `OrderReleaseJob.java:210-214` — the two-key busy skip in `runFor` logs at **DEBUG** and `continue`s, no metric.
- `OrderReleaseJob.java:303-307` — the manual busy skip logs at DEBUG, no metric (correct per the family rule that `runForCurrentTenant` touches no metrics).

Net effect: the counter `wms2.cron.order_release.skipped_lock_busy` will never be created again, so a tenant that is skipped **every occurrence** because its lock is persistently held is invisible above DEBUG. This matches the other no-dual-lock siblings (`StaleClubBatchCleanupJob`, `ReleaseExpiredPickingOrdersFromUserJob` record nothing either), so it is a *family* behaviour rather than a divergence — but it **is** a behaviour change from this job's own pre-D′ shape, and the class javadoc, which otherwise enumerates every metric decision line by line (`OrderReleaseJob.java:76-81`), does not mention it.

Compounding it, the test that reads like the guard is now vacuous. `OrderReleaseJobUnitTest.java:368-369`:

```java
@DisplayName("does not touch the whole-run gauges (markLastRun/recordDuration/skippedLockBusy) — those describe a scheduled runFor() fire, not a manual trigger")
```
…and `:388`:
```java
assertThat(registry.find("wms2.cron.order_release.skipped_lock_busy").counter()).isNull();
```

For the sibling this assertion is meaningful (there, `runFor` *does* write that counter, so `runForCurrentTenant` not writing it is a real distinction). Here nothing writes it on any path, so the assertion passes for a reason unrelated to what its `@DisplayName` claims — it would still pass if `runForCurrentTenant` were changed to call every metric except that one. It is not wrong, but it is not evidence.

**Recommendation:** either state the drop explicitly in the class javadoc's metrics paragraph (one sentence: "the two-key busy skip records no counter, unlike the dual-lock siblings — a persistently locked-out tenant is DEBUG-only"), or record `skippedLockBusy()` on `runFor`'s two-key skip. Also drop `skippedLockBusy` from that `@DisplayName` so it does not read as a claim the assertion cannot support. Operational urgency is low — nothing scrapes Prometheus in this estate yet — but the javadoc claim should match the code.

#### M-3 — the commit's "sweep stale single-trigger-count comments" claim is incomplete; the biggest count claim in the file was missed

Commit message: *"SchedulingConfiguration: … update `configureAllTasks()` and **sweep stale single-trigger-count comments**."* The sweep did catch `:631` (three→four grouped), `:635` (two single-trigger reads — correct: `replenish` + `releaseExpiredPickingOrdersFromUser`), `:1062` and `:1094` and `:1570`. It missed `SchedulingConfiguration.java:290-303`:

> `<p><b>Still one shared schedule for five of the six jobs.</b> … the winning tenant's {@code *_TIMER_*} sysprops still drive the five NOT-YET-CONVERTED jobs for every tenant … the sixth job, {@code staleClubBatchCleanup}, is converted … Until the remaining five convert, AC5's provenance logging is what makes the arbitrary winner visible.`

As of this commit **five of six are converted** (`staleClubBatchCleanup`, `stockSummaryExport`, `cleanUpOldMessages`, `releaseExpiredPickingOrdersFromUser`, `orderRelease`) and exactly **one** — `replenish` — is not. The paragraph asserts the precise inverse.

This staleness is *pre-existing* (it was already wrong after steps 4, 5.1 and 5.2, none of which fixed it), so it is not a defect this PR introduced. It is Medium rather than Low only because the commit message asserts a completeness word ("sweep") over exactly this category, and this is the file's single most load-bearing count claim — it is the paragraph a newcomer reads to learn what D′ has and has not done.

**Recommendation:** rewrite `:290-303` to "one shared schedule for the ONE remaining unconverted job (`replenish`)", or drop the completeness word from the commit message.

---

### Low

#### L-1 — `OrderReleaseJobUnitTest`'s nested class is still called `doCalculation`
`src/test/java/net/aim_ai/wms/unit/schedulejob/OrderReleaseJobUnitTest.java:141-143`:
```java
@Nested
@DisplayName("doCalculation")
@Disabled("Pre-existing env issue: landlord datasource not configured (SBDEV-2099 env skip)")
class DoCalculation {
```
Both tests inside now call `runFor(ANY_SPEC)` / `runForCurrentTenant()`; the method the display name refers to no longer exists. `OrderReleaseJobTest`'s four sibling nested classes had their `@DisplayName`s correctly updated to `"runFor - …"` (`:112`, `:212`, `:323`, `:459`) while keeping the old Java identifiers, so this one looks like an oversight rather than a convention. (The Java identifiers `DoCalculationHappyPath` etc. are harmless and not worth churning.)

#### L-2 — the `viaFindByActiveTrue` test's inline comment names a mechanism the test does not exercise
`src/test/java/net/aim_ai/wms/unit/schedulejob/OrderReleaseJobUnitTest.java:96-97`:
```java
// Per-tenant loop short-circuits (job not activated / no schedule) before touching deeper collaborators.
when(syspropService.getSysvalue(anyString())).thenReturn("false");
```
Neither named path is what actually happens. `"false"` is non-blank, so `deriveSpecForCurrentTenant()` (`OrderReleaseJob.java:143`) does **not** return `null`; it proceeds to `timezoneService.getWarehouseZoneId("wh01")`, which is an unstubbed mock returning `null`, so `TriggerSpec.of(cron, null)` throws at its `Objects.requireNonNull(zone, "zone")` (`TriggerSpec.java:48`). That lands in `runFor`'s derivation `catch` at `:188` → `anyReadFailure = true` → `continue`. The activation check at `:218` is never reached.

The test's assertions (`findByActiveTrue` called, `findAll` never) are still valid and still test what the `@DisplayName` says, so this is a comment defect, not a green-for-the-wrong-reason failure. It is also why the fixture at `:93` gets away with no `.setId(...)`: it never reaches `long tenantId = config.getId()` at `:199`. **I swept every other `new TenantDbConfiguration()` in the touched test files** — `OrderReleaseJobMetricsUnitTest:100`, `OrderReleaseJobSectionGuardTest:88`, `OrderReleaseJobStreamingTest:82`, `OrderReleaseJobTest:84` and `:367`, `OrderReleaseJobUnitTest:118/219/253/342`, `WholeRunSuccessGaugeUnitTest:275-279`, and both fixtures in `AdminTriggerTenantScopeUnitTest.cronRun_stillLoopsEveryActiveTenant` — **all of them set an id.** The only two that do not (`OrderReleaseJobUnitTest:93` and the shared `AdminTriggerTenantScopeUnitTest.config(...)` helper at `:196-202`) are both on paths that never reach the unboxing. No missed fixture.

#### L-3 — `schedulerRejectingEveryTriggerReportsZero`'s assertion cannot distinguish which error line fired
`src/test/java/net/aim_ai/wms/schedulejob/SchedulingConfigurationUnitTest.java:827`:
```java
.anySatisfy(m -> assertThat(m).contains("Failed to configure orderRelease group"));
```
`configureOrderReleaseGroups` emits two different ERRORs: the per-group `"Failed to configure {} group {} for tenant(s) {}"` (`SchedulingConfiguration.java:875`) and the whole-method catch-all `"Failed to configure {} groups"` (`:886`). `"…orderRelease groups"` contains `"orderRelease group"` as a prefix, so the assertion is satisfied by either. The test is exercising the per-group path (the scheduler throws inside `register`), but the assertion does not pin that. Adding `" for tenant(s)"` to the expected substring would close it. The same looseness exists in the already-merged sibling assertions, so this is consistency, not a regression.

#### L-4 — `"Adds six more triggers every cycle"` is now a floor, not a count
`src/main/java/net/aim_ai/wms/schedulejob/SchedulingConfiguration.java:1247`. With four grouped jobs the hypothetical re-derive-without-cancelling failure mode adds one trigger *per distinct spec per job*, which is ≥ 6 and grows with tenant-schedule divergence (the same paragraph at `:1267-1268` documents three different `STOCK_SUMMARY_EXPORT_TIMER_HOUR` values across environments). The paragraph is describing a road-not-taken, so nothing is broken; "six" is just no longer the right number.

#### L-5 — `triggerOrderReplenish` can now report `false` for a run in which `replenish` succeeded
`src/main/java/net/aim_ai/wms/controller/AdminActionController.java:106-118`. The returned boolean reflects only `orderReleaseJob.runForCurrentTenant()`; `replenishJob.doCalculation(false)` still runs unconditionally and its outcome is unobservable. The endpoint's own comment says exactly this and flags it for revisit in part 4, which is the right disposition — and I confirmed there is **no consumer impact**: the only caller, `v2/wms2-web-ui/store/admin/mgmt/action.js:17-18`, does `console.log('triggerOrderReplenishment returned', results)` and never branches on the value. Noting it only so part 4 does not lose the thread. The honesty change itself is an improvement over the previous hardcoded `true`, and `AdminActionControllerUnitTest.surfacesOrderReleaseRefusalInsteadOfHardcodedSuccess` pins it.

#### L-6 — inherited: `markLastSuccess()` fires on a run where every tenant was unreadable
`OrderReleaseJob.java:252` — `if (!anyFailure) jobMetrics.markLastSuccess();`. `anyReadFailure` does not gate it, so a fire in which every tenant's `deriveSpecForCurrentTenant()` threw (all tenant DBs down) records `anyMember=false, anyFailure=false, anyReadFailure=true` and still greens the freshness gauge. This is **byte-identical to the already-merged `CleanUpOldMessagesJob:192`** and to the other converted siblings, so it is an inherited family property that PR #291/#293/#296 already accepted, not something this PR introduces. Recorded here only so it is not re-discovered as new in part 4. Do not fix it in this PR — if it is worth changing it should change across all five jobs at once.

---

## 5. Test-arithmetic verification (all correct)

Re-derived independently rather than trusting the PR's edits. `EXPECTED_TRIGGER_COUNT = 6` (`SchedulingConfigurationUnitTest.java:86`), one per job.

| Test | Claimed | Derivation | ✔ |
|---|---|---|---|
| `differentZonesMeanTwoGroups` (`:985`) | `+ 4` | 4 grouped jobs × 2 zones (8) + 2 single-trigger (2) = 10 = 6+4 | ✔ |
| `staleClubNoSchedule…` (`:1152`) | `+ 3` | baseline +4, minus staleClub's LA group only (its own mock is gated; the other three grouped jobs still register both zones) | ✔ |
| AC11 additive test (`:1212`) | `+ 4` | one new LA group added per grouped job | ✔ |
| `callerContextIsRestored` (`:1252`) | `+ 4` | same as `differentZonesMeanTwoGroups` | ✔ |
| `SchedulingReconcileIdempotencyUnitTest` swap count (`:576`) | `1` cancelled | only `replenish` is still single-trigger *and* moves with `timerValue`; `releaseExpiredPickingOrdersFromUser` is hard-coded `"40 * * * * *"`; the four grouped jobs add new keys rather than swapping | ✔ |
| reconcile `+ 3` (`:783`, `:788`) | `+ 3` | `stockSummaryExport` + `cleanUpOldMessages` + `orderRelease` each gain a group; `staleClubBatchCleanup`'s mocked derivation ignores `timerValue` | ✔ |
| `reconcileFillsOnlyTheGap` (`:849`, `:872`) | `+ 3` | staleClub heals in, plus the three groups above | ✔ |
| `NeverMatcher…` `AdminTriggerTenantScopeUnitTest:6` | 6 | hand-counted: `anyLong()` ×2 at `:316`, `:446`, `:567` = 6 | ✔ |
| `NeverMatcher…` `OrderReleaseJobUnitTest:7` | 7 | hand-counted: `:133` (2), `:155` (1), `:244` (2), `:264` (2) = 7 | ✔ |
| inventory total "171 across 39 classes" | 171 / 39 | summed the 39 entries: 171 | ✔ |

`RunForCurrentTenantLocking`'s eight scenarios each exercise what they claim — I traced each to the specific `OrderReleaseJob` line it refuses at (`:290` empty row, `:297` int4, `:303` lock-busy, `:309` not-activated / global-switch-off, `:317` release-threw, `:303`/`:321` correct-tenant-id, and the registry reads for the no-gauges case). `locksOnTheCallersOwnTenantId` additionally pins `never()).tryLock(…, 1L)`, which is what makes it a *correct-tenant* test rather than a *some-tenant* test.

---

## Verdict

**APPROVE WITH NITS** — the conversion itself is correct and unusually well-evidenced: business logic is byte-identical to pre-D′, the wrapper is structurally identical to the already-merged `CleanUpOldMessagesJob` modulo the deliberate dual-lock omission (which I verified independently against `ReleaseOrderJobService`'s `FOR UPDATE` + fresh state re-check rather than trusting the javadoc), the activation check is preserved and *covered* on both paths, the metrics split is real rather than asserted, and every count claim in the test surgery holds when re-derived by hand. All three Mediums are documentation-accuracy defects with no functional consequence — M-1 and M-3 are stale comments that this PR's own scope obliged it to update, and M-2 is an undisclosed (and inherited-shaped) observability drop plus one assertion that no longer proves what its display name says. None of them block merge; all three are one-or-two-line edits.
