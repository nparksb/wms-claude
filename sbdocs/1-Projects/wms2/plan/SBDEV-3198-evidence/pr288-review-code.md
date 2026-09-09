---
name: pr288-review-code
description: Independent code review of wms2-api PR #288 (SBDEV-3198 step 4, StockSummaryExportJob → D′) at commit 680f1f15
lane: code review (independent — this lane did not author the PR)
reviewed: 2026-09-03
base: 3941fb26 (develop tip, post-#286/#287)
head: 680f1f15
worktree: /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-288-review-a
---

# PR #288 — independent code review

## Verdict

**FIX BEFORE MERGE.** The conversion is structurally correct and the six load-bearing claims in the
PR description all hold *as written* — but the dual-lock's one-key acquisition is scoped to the whole
trigger fire, which turns two *legitimately concurrent groups* of the same job into "one exports,
the other silently loses its whole night" (H-1), and **both** of `runFor`'s unlock paths are
completely unpinned by tests — I deleted each one and 124 tests stayed green (H-2). On the job
carrying the live symptom and a real OMS side effect, those two together are a merge blocker.

Counts: **2 High**, **4 Medium**, **5 Low**.

## Evidence collected

| Instrument | Result |
|---|---|
| `mvn -o clean test-compile` | BUILD SUCCESS (41s) |
| `mvn -o test -Dtest='StockSummaryExportJob*,SchedulingConfigurationUnitTest,SchedulingReconcileIdempotencyUnitTest,WholeRunSuccessGaugeUnitTest,NeverMatcherNullBlindnessArchTest,StaleClubBatchCleanupJob*,AdminActionControllerUnitTest,StockCountRestControllerUnitTest'` | **164 run, 0 failures, 0 errors** |
| Hand mutant A — delete `advisoryLockService.unlock(STOCK_SUMMARY_EXPORT)` from `runFor`'s `finally` (`StockSummaryExportJob.java:269`) | **SURVIVED** — 124/124 green |
| Hand mutant B — delete `advisoryLockService.unlock(STOCK_SUMMARY_EXPORT, tenantId)` from the per-tenant `finally` (`:245`) | **SURVIVED** — 124/124 green |
| Stale-reference sweep `grep -rn "StaleClubBatchCleanupJob.TenantSchedule" src/` | **0 hits** — claim #4 verified |
| Literal sweep `grep -rn '"stockSummaryExport"' src/main` | 1 hit, the `JOB_NAME` constant itself — no missed sibling literal in main |
| Trigger-count arithmetic | 3 assertions re-derived independently from production code — all **correct** (see §Verified below) |
| H-1 fix (separate `ThreadLocal` slots per lock form) actually on `develop` | **Confirmed** — `AdvisoryLockService.java` declares `lockedConnection` *and* `lockedTenantConnection`, and the class javadoc explicitly blesses holding one of each simultaneously |

Worktree restored to a clean `680f1f15` after mutation (`git status --porcelain` empty).

---

## H-1 (High) — the one-key lock is held for the WHOLE fire, so two concurrent groups of this job are mutually exclusive: the loser exports nothing, at DEBUG

`src/main/java/net/aim_ai/wms/schedulejob/StockSummaryExportJob.java:174-181`

```java
public void runFor(TriggerSpec spec) {
    long startNanos = System.nanoTime();
    if (!advisoryLockService.tryLock(AdvisoryLockService.JobLockId.STOCK_SUMMARY_EXPORT)) {
        LOG.debug("{} trigger {} skipped this occurrence — one-key lock held (old-code replica "
            + "or another group's outer hold), transitional per the dual-lock deploy note", ...);
        jobMetrics.skippedLockBusy();
        return;
    }
```

The javadoc's own parenthetical — *"or another group's outer hold"* — names the bug and then accepts
it. But this is not the same cost as the pre-D′ job-wide skip, because pre-D′ there was exactly ONE
trigger, so "skip the whole fire" and "skip nothing that another fire won't cover" were the same
statement. After this PR there are N triggers, and the one-key lock makes them **mutually exclusive
across the entire per-tenant walk**.

Two ways this bites, neither exotic:

1. **Coincident instants.** `TriggerSpec` groups on `(cron, zoneId)`, so two tenants with the same
   `hour`/`minute` sysprops in two zones at the *same UTC offset* (`America/New_York` +
   `America/Toronto`, or `America/Los_Angeles` + `America/Vancouver`) are two distinct groups that
   fire at **identical instants, every night**. `POOL_SIZE = 10` (`SchedulingConfiguration.java:228`)
   so both are dispatched concurrently on different pool threads, each with its own pooled landlord
   connection ⇒ genuinely different PG sessions ⇒ the second `pg_try_advisory_lock(100004)` fails.
   Also hits `22:00 America/New_York` vs `19:00 America/Los_Angeles`.
2. **Overlap, which needs no coincidence at all.** The one-key lock is held from `:176` to the
   `finally` at `:269` — i.e. across the *entire* walk of every member tenant's full-inventory
   export. A group whose export runs 40 minutes blocks any group firing inside that window
   outright.

Failure scenario: hydra/nywh (`America/New_York`, 03:00) and shipitez/nywh (`America/Toronto`,
03:00) land in different groups. Every night one group wins the one-key lock and exports; the other
returns at `:181` having exported **nothing for any of its tenants**. The only signal is a
`LOG.debug` and a `skipped_lock_busy` counter tick — and the winning group calls `markLastSuccess()`
(`:267`), so `last_success_epoch_seconds` advances and freshness alerting reads **healthy**. OMS
receives a stale full-inventory snapshot for those tenants indefinitely. That is §1.1's symptom
re-created through the mitigation intended to make the conversion safe.

The plan's §7a step 4 decision record costed the dual-lock against the *rolling-deploy drain window*
only; intra-process cross-group contention is not costed anywhere in it, and the AC7 arithmetic at
§7a step 3 explicitly reasons from "UAT's two groups are three hours apart, never coincident" — a
fixture property of today's sysprop values, not an invariant, and one this job's own tenant-editable
`STOCK_SUMMARY_EXPORT_TIMER_HOUR` can void without a deploy.

Note that step 3's `StaleClubBatchCleanupJob` takes **no** one-key lock at all, so the D′ shape
demonstrably does not need it — the one-key acquisition here is purely the deploy mitigation.

**Fix (smallest correct):** move the one-key acquisition **inside** the per-tenant loop, wrapping
the two-key acquisition (take one-key → take two-key → work → release two-key → release one-key,
sequentially per tenant). It is never nested with itself, so `AdvisoryLockService`'s "never nest two
locks of the same form" rule still holds, and it preserves the whole point of the mitigation (an
old-code replica holding `100004L` for its fleet walk still excludes the new code). What changes is
the blast radius: a busy one-key then costs **one tenant this occurrence**, not an entire group's
night. Also raise `:177` from `LOG.debug` to `LOG.warn` — a skipped nightly export is not debug
information — and add a `runFor`-level test that a busy one-key performs no export (today only the
`skipped_lock_busy` counter is asserted, in `StockSummaryExportJobMetricsUnitTest`, with nothing
pinning that the export did not happen).

## H-2 (High) — both of `runFor`'s unlock paths are unpinned; deleting either leaves 124 tests green

`StockSummaryExportJob.java:245` (per-tenant two-key) and `:269` (one-key, in the `finally`)

The only `unlock` assertions anywhere in the changed tests are on `runForCurrentTenant`:

```
src/test/java/.../StockSummaryExportJobUnitTest.java:390   verify(advisoryLockService, never()).unlock(..., 1L);
src/test/java/.../StockSummaryExportJobUnitTest.java:414   verify(advisoryLockService).unlock(..., 42L);
```

`runFor` — the scheduled path, the one that actually holds two locks at once — has none. Measured:

- **Mutant A**: removed `advisoryLockService.unlock(AdvisoryLockService.JobLockId.STOCK_SUMMARY_EXPORT);`
  from the `finally` at `:269`. `StockSummaryExportJob*`, `SchedulingConfigurationUnitTest`,
  `SchedulingReconcileIdempotencyUnitTest`, `WholeRunSuccessGaugeUnitTest` → **124 run, 0 failures.**
- **Mutant B**: removed the per-tenant `unlock(..., tenantId)` from the `finally` at `:245`
  → **124 run, 0 failures.**

Failure scenario for A: a leaked one-key advisory lock is *session*-level on a `ThreadLocal`-pinned
raw connection, so it is never released until the JVM restarts. Every subsequent `runFor` on that
replica takes the `:176` branch and skips — the nightly full-inventory export stops fleet-wide, for
every group, permanently, reported only at DEBUG while `skipped_lock_busy` climbs. For B: the
leaked two-key connection is *overwritten* on the next tenant (`lockedTenantConnection.set(conn)`),
which `AdvisoryLockService`'s class javadoc names as exactly the leak it warns about — so a
one-tenant leak silently becomes one leaked connection *per member tenant per night*.

Both are precisely the class of defect the repo's five-item floor requires a mutation check to
catch, and both regress a `finally` that no test observes. This is the same shape the step 3 review
already paid for once (F-7 on `AdvisoryLockService`).

**Fix:** add two `runFor` tests — (a) a tenant whose `exportStockSummary` throws still releases
*both* its two-key lock and the outer one-key lock (`verify(advisoryLockService).unlock(ID, 1L)` +
`verify(advisoryLockService).unlock(ID)`); (b) a two-tenant group releases the two-key lock twice
and the one-key lock exactly once. Mutation-check each new assertion by deleting the `finally` body
it protects.

## M-1 (Medium) — a NON-MEMBER tenant's read failure sets `anyFailure` and writes `tenantFailure`, once per group per night

`StockSummaryExportJob.java:246-253`

```java
} catch (Exception e) {
    anyFailure = true;
    jobMetrics.tenantFailure(tenantName, e.getClass().getSimpleName());
    LOG.error("Error processing tenant {} - {}", ...);
    anyReadFailure = true;
}
```

The `try` this catches opens at `:204`, **before** the membership test at `:210`
(`if (own == null || !own.spec().equals(spec)) continue;`). `deriveSpecForCurrentTenant()` reads two
sysprops from the *tenant* DB, so a tenant whose DB is unreachable throws here — and is charged a
`tenantFailure` and flips `anyFailure` even though it is not in this trigger's group at all.

Because every group's `runFor` walks **every** active tenant, one unreachable tenant produces
G × `wms2.cron.stock_summary_export.failure{tenant=X}` increments per cycle (pre-D′: exactly 1), and
withholds `markLastSuccess()` in **every** group. So `last_success_epoch_seconds` never advances
even though every member tenant of every group exported cleanly.

That inverts the tradeoff the class javadoc documents at `:67-73`, which describes only the
optimistic direction — *"fleet-health alerting goes green whenever ANY group succeeds this cycle."*
The pessimistic direction is equally live and undocumented: **any group seeing any failing tenant,
member or not, withholds the gauge, and every group sees every tenant.** An operator reading that
javadoc will mis-diagnose the resulting permanent-stale gauge.

The step 3 reference conversion does **not** do this: `StaleClubBatchCleanupJob.java`'s equivalent
catch sets only `anyReadFailure`, with a comment explaining that by the time real work can throw,
`anyMember` is already true. PR #288 claims to *"mirror exactly"* that method (`:164-167`).

**Fix:** wrap the derivation in its own `try` that sets only `anyReadFailure` and `continue`s; let
the outer catch (which then covers only post-membership work) keep `anyFailure` + `tenantFailure`.
Add a two-tenant test where the non-member tenant's derivation throws and assert
`markLastSuccess()` is still called and no `failure` counter exists for it.

## M-2 (Medium) — `runForCurrentTenant()` silently drops the whole-run metrics `doCalculation(false)` wrote; the javadoc and the plan both claim behaviour is preserved "EXACTLY"

`StockSummaryExportJob.java:280-289` (javadoc) and `:288-322` (body)

> *"Behaviour preserved EXACTLY from `doCalculation(false)`: no activation-flag check, no per-tenant
> `JobMetrics` … The ONE deliberate change is the lock."*

That is not accurate. The deleted `doCalculation(Boolean)` reached a shared `finally` regardless of
`isCronJob`, so **every** manual trigger recorded `jobMetrics.markLastRun()` and
`jobMetrics.recordDuration(...)`, and a contended lock recorded `jobMetrics.skippedLockBusy()`
before returning. `runForCurrentTenant()` records **none** of the three. The dropped metrics are not
"per-tenant `JobMetrics`" — they are the whole-run gauges the javadoc's own next paragraph is about.

I think the new behaviour is the *better* one (a manual trigger writing `last_run` masks a dead
cron), so this is a disclosure and test-coverage defect rather than a wrong choice. But it is an
undisclosed monitoring change on two already-shipped endpoints
(`AdminActionController.triggerUpdateStock`, `StockCountRestController.triggerStockCount`), it is
repeated verbatim in the plan's §7a step 4 entry, and **nothing pins it either way** — a future
"restore the missing metrics" edit would be green.

**Fix:** correct both javadocs to state the metric change explicitly and why, and add
`verify(jobMetrics, never()).markLastRun()` (or the intended positive assertion) to
`RunForCurrentTenantLocking`.

## M-3 (Medium) — the dual-lock doubles this job's simultaneous landlord-pool holdings to 2, against an in-repo cap of 2, and the "≫2" that makes it safe has never been read from the running environment

`StockSummaryExportJob.java:176` + `:224` held simultaneously; `src/main/resources/application.properties:66`

```
landlord.datasource.maximum-pool-size=2
```

`AdvisoryLockService` pins one raw `landlordDataSource` connection **per held lock form**. Holding
one-key *and* two-key means this job occupies **2 of 2** landlord connections for the entire
duration of each member tenant's export — not, as the plan's §7a step 4 rationale says, *"only
during the overlap window."*

Every other consumer of that pool then starves for the whole nightly run. That includes the six
other jobs' own `tryLock` calls: `AdvisoryLockService.tryLock` catches `SQLException` and returns
`false` (`AdvisoryLockService.java:101-103`), so a Hikari connection-timeout there is
indistinguishable from "another replica holds it" — `orderRelease` and `replenish` would log
`Failed to acquire advisory lock` and **skip every minute** of the export window, which is the
"288 lost order-release minutes" failure mode AC14 exists to prevent, arriving from a different
direction.

The plan's headroom argument (§2.3.1) rests on **20 idle server-side connections observed on the prd
landlord DB**, which it itself flags as a *"factor-of-five contradiction"* with the per-JVM cap of 2
and resolves only by inference (*"either the cap is overridden in the Portainer stack environment,
or something outside `wms2-api` connects"*). §7a step 3 still lists *"the real `LandlordHikariPool`
cap"* as an **open verification item**. Doubling the holding while that is open is the wrong
ordering.

**Fix:** read the running cap before merging — `hikaricp.connections.max` for the landlord pool off
the actuator on dev/uat, or `SHOW max_connections` plus a `pg_stat_activity` sample under a
deliberately-held lock. If it really is 2, H-1's per-tenant one-key scoping fixes this too (the
one-key connection is then held for one tenant, not the whole walk) — which is a second reason to
prefer that fix.

## M-4 (Medium) — two divergences from step 3's reviewed reference, both of which that review explicitly paid to remove

`StockSummaryExportJob.java:214-222`

```java
long tenantId = config.getId();
try {
    Math.toIntExact(tenantId);
} catch (ArithmeticException e) {
    LOG.error("{}: tenant_db_configuration.id {} does not fit int4 — ...", ...);
    anyReadFailure = true;
    continue;
}
```

Against `StaleClubBatchCleanupJob.java`'s reviewed form:

1. **`anyReadFailure = true` is a dead store here.** `anyMember = true` is set at `:212`, two lines
   above, so the only reader (`if (!anyMember)` at `:258`) is unreachable for this tenant. Step 3's
   L-3 removed exactly this assignment, with a comment recording that a reviewer's mutant ledger
   caught it. It is reintroduced verbatim.
2. **`Math.toIntExact(tenantId);`'s result is discarded.** Step 3's L-2 deliberately writes
   `int objId = Math.toIntExact(tenantId); LOG.trace(...)` precisely because a bare call *"a static
   analyser would flag as dead and a future reader would delete."* PR #288 reverts to the bare call.

Neither is a live defect today. Both matter because this is the *pattern* four more jobs will be
cloned from in step 5 (the plan says so explicitly), and #2 in particular is a latent removal
waiting for a cleanup pass — deleting that line silently disables the int4 guard, and no test would
notice (there is no `runFor` int4-overflow test; only `runForCurrentTenant` has one).

**Fix:** align both with the step 3 form, and add the missing `runFor` int4-overflow test so the
guard is observable.

## L-1 (Low) — `runForCurrentTenant`'s tenant resolution uses a case-sensitive lookup where the request has already proven a working resolution exists

`StockSummaryExportJob.java:294-295`

```java
Optional<TenantDbConfiguration> config = tenantDbConfigurationRepository
    .findByTenantNameAndWarehouse(current.getTenantName(), current.getFacilityCode());
```

`TenantFilter.java:47` builds the profile as
`new TenantProfile(tenantName.toLowerCase(), facilityCode.toLowerCase())`, and this derived JPA
finder is case-sensitive. Today's landlord rows are lowercase (`hydra`/`nywh`, `wineco`/`wsl`), so it
matches — but a single mixed-case `tenant.name` or `warehouse` row would turn a working manual export
into a silent refusal at `:298`, on an endpoint that still answers `200 true`. The request reaching
this line has *already* routed successfully to the tenant DB, so a resolution that cannot fail is
available (the `dbConfigCache` / `TenantKeyBuilder` path `SchedulingConfiguration` itself uses).
Cheap hardening: resolve through the cache, or lowercase both sides at the lookup.

## L-2 (Low) — both refusal paths and the lock-busy path answer `200 true`

`AdminActionController.java:118` returns `ResponseEntity.ok(true)` unconditionally. An operator who
triggers "update stock" while the tenant has no landlord row (`:298`), an int4-overflow id (`:305`)
or a busy two-key lock (`:309`) is told `true` while nothing was exported. Pre-existing for the
lock-busy case; this PR adds two more silent-success paths. Worth surfacing a distinguishable
response now that there are three of them.

## L-3 (Low) — stale comments in `configureAllTasks`

`SchedulingConfiguration.java:630-634`

> `// D′ grouped job FIRST, deliberately. It walks every tenant's context and must restore the`
> `// caller's afterwards; running it first makes that restore LOAD-BEARING — if it were dropped,`
> `// the five reads below would run with no context and refuse`

There are now **two** grouped jobs (not one) and **four** single-trigger reads below them (not five).
The reasoning still holds; the numbers no longer do. The tests were updated for exactly this count
change ("all four single-trigger jobs registered") while this comment was not.

## L-4 (Low) — `noScheduleTenantIsNamed`'s ERROR assertion no longer identifies which job logged it

`src/test/java/net/aim_ai/wms/schedulejob/SchedulingConfigurationUnitTest.java:1090-1100`

```java
assertThat(messagesAt(Level.ERROR))
    .anySatisfy(m -> assertThat(m).contains("timer sysprops absent or blank").contains(LA_KEY));
```

Both grouped jobs now emit that identical message shape (`SchedulingConfiguration.java:775` for
stockSummaryExport, and its staleClub sibling). The assertion passes if *either* job logs it, so a
regression that stopped staleClub logging while stockSummaryExport still did would go unnoticed. The
fixture happens not to construct that case today. Add `.contains("staleClubBatchCleanup")`.

## L-5 (Low) — two migrated fixtures now set a `TenantContext` they previously ran without

`StockSummaryExportJobBulkInsertTest.java` and `StockSummaryExportJobOmsDecouplingTest.java` both
gained `TenantContext.setCurrentTenant(new TenantProfile("acme", "wh01"))` in `setUp` (needed, since
`runForCurrentTenant` resolves it). Fine functionally, but `OmsDecouplingTest` asserts a
*threading* contract across a `TenantAwareTaskDecorator`-decorated consumer thread, and that
decorator's behaviour differs between a null and a non-null context. The assertion still passes and
the intent is preserved, but the fixture is now exercising a different context-propagation path than
the one the test was written against. Worth a line in the class javadoc.

---

## Verified — claims that hold

**Claim #1 (dual-lock mechanics), partially.** One-key taken once at `:176`, released in a `finally`
covering the whole method (`:268-272`). The early return at `:181` is *before* the `try`, so no
`unlock` of a lock never held. Two-key taken per tenant at `:224` and released in a per-tenant
`finally` at `:244-246` — so a throwing tenant does not leak it, and the not-activated `continue` at
`:236` still passes through that `finally`. The H-1 fix is genuinely on `develop`: `AdvisoryLockService`
declares `lockedConnection` and `lockedTenantConnection` as separate `ThreadLocal`s and the class
javadoc explicitly permits holding one of each. **But** see H-1 for the *scope* of the one-key hold
and H-2 for the absence of any test on either release.

**Claim #2 (`runForCurrentTenant` resolution), except M-2/L-1.** It resolves the caller's own tenant
via `TenantContext` + `findByTenantNameAndWarehouse` — the correct tenant-scoped unique finder
(`TenantDbConfigurationRepository.java:39`, the deliberate SBDEV-3192 survivor of the
warehouse-only-lookup purge), not a `findByWarehouse`. It refuses (log + return, no export, no lock)
on null context, empty lookup and int4 overflow; the two-key lock is released in a `finally`
(`:318-320`). `exportStockSummary(null)` is called unchanged, with no activation-flag check and no
per-tenant metrics, matching `doCalculation(false)`. `StockCountRestController.triggerSchedule()`'s
`Runnable` is invoked synchronously on the same request thread (`:106`), so the two-key lock's
`ThreadLocal` pairing is safe.

**Claim #3 (per-group metrics).** All five whole-run writes are once per group fire and nowhere else:
`skippedLockBusy` at `:180` (busy path only), `markLastSuccess` at `:187` (empty fleet) and `:267`
(clean run), `markLastRun` + `recordDuration` at `:270-271`. No double-count is possible — and
`WholeRunSuccessGaugeUnitTest`'s pins are strong enough to prove it, since
`assertCleanRunSetsSuccessGauge` asserts `verify(jobMetrics, times(1)).markLastSuccess()` over a
**two-tenant** fixture, so moving the write into the loop would fail. `assertMixedRunWithholdsSuccessGauge`
asserts `never()`. The updated class javadoc's honesty about *why* the pin still holds (one group in
this fixture, "not because per-group writes were made safe in general") is exactly right, and it
matches the implementation. The residual gap is directional, not structural — see M-1.

**Claim #4 (`TenantSchedule` promotion).** Zero stale `StaleClubBatchCleanupJob.TenantSchedule`
references anywhere under `src/`. The record moved to a top-level `public record` with the M-3
review note carried across intact; the nested copy is deleted; all three referencing sites
(`SchedulingConfiguration`, `SchedulingConfigurationUnitTest`, `SchedulingReconcileIdempotencyUnitTest`,
`StaleClubBatchCleanupJobDeriveSpecUnitTest`) updated. Clean.

**Claim #5 (SBDEV-3102 duplicate pair).** `StockSummaryExportJobTest` and
`StockSummaryExportJobUnitTest` were migrated by entry-point substitution only — every assertion,
`verify` count, `times(n)` and `never()` is byte-identical across the diff. Nothing was weakened or
dropped to fix a compile error. Same for `BulkInsertTest`, `OmsDecouplingTest` and `MetricsUnitTest`.
`StockSummaryExportJobUnitTest` gained a genuinely new `RunForCurrentTenantLocking` nested class
(4 tests) that pins the caller's-own-id behaviour, including a `tryLock(..., 42L)` /
`never() tryLock(..., 1L)` pair that would catch a hard-coded id. The
`NeverMatcherNullBlindnessArchTest` inventory bump 144 → 148 is arithmetically right: 2 new tests ×
2 `anyLong()` occurrences inside `never()`, and the ArchTest itself passes.

**Claim #6 (trigger-count arithmetic).** Re-derived three independently from production code, all
correct (`EXPECTED_TRIGGER_COUNT = 6` = the six entries of `CONFIGURED_JOB_NAMES`):

- `differentZonesMeanTwoGroups` → `EXPECTED + 2` = **8**. Two tenants, NY + LA. 4 single-trigger jobs
  (`cleanUpOldMessages`, `orderRelease`, `replenish`, `releaseExpiredPickingOrdersFromUser`) + 2
  staleClub groups + 2 stockSummaryExport groups. ✔
- `noScheduleTenantIsNamed` → `EXPECTED + 1` = **7**. `staleClubNoSchedule.add("wsl")` gates only
  staleClub's stub, so staleClub gets 1 group (NY) while stockSummaryExport still gets 2:
  4 + 1 + 2 = 7. ✔
- `reconcileFillsOnlyTheGap` → `EXPECTED + 1` = **7**. Boot with `staleClubSpec = null` registers 4
  single + 1 stockSummary group = 5 ("boot's 5", as the comment says); the reconcile heals staleClub
  in (+1) and adds stockSummaryExport's new `0 9 9`@LA group (+1) = 7 registrations and 7 registry
  entries. ✔ The paired `cancelled == 3` change is right too: of the four jobs that used to
  reschedule, `stockSummaryExport` is now grouped and never swaps, and
  `releaseExpiredPickingOrdersFromUser` (`SYSPROP_FREE_JOB`) never rescheduled.

The `configureStockSummaryExportGroups` implementation genuinely mirrors its sibling: identical
tenant walk, identical malformed-row guard, `callerContext` saved and restored in a `finally`, the
`CRON_JOB_SHOW_LOG` read placed *after* that restore (so it runs under the probe tenant, which the
tests pin as `..._SHOW_LOG_KEY + "@nywh"`), the `reconciling && registrations.containsKey(...)`
additive gate placed *before* the `showLog` read (so a no-op reconcile reads no sysprop, which
`reconcileReadsNoSyspropWhenNothingIsMissing` pins), and the M-7 ground-truth
`registeredJobNames().contains(JOB_NAME)` return. Registration ordering (both grouped jobs before
the four `onlyIfMissing` calls) keeps the context-restore load-bearing. Correct.

---

## Recommended pre-merge set

1. **H-1** — scope the one-key acquisition per tenant; raise the skip log to WARN; add a
   `runFor`-level "busy one-key exports nothing" assertion.
2. **H-2** — two `runFor` unlock tests, each mutation-checked.
3. **M-1** — narrow the catch so a non-member tenant's read failure cannot write `tenantFailure` or
   flip `anyFailure`; document the pessimistic direction of the AC6 tradeoff.
4. **M-2** — correct the "preserved EXACTLY" claim in the javadoc *and* in the plan's §7a step 4
   entry; pin the metric behaviour.
5. **M-3** — read the running landlord `maximumPoolSize` before merging (H-1's fix also mitigates).
6. **M-4** — realign with step 3's reviewed form before step 5 clones this pattern four more times;
   add the `runFor` int4-overflow test.
7. **L-1 … L-5** — same pass, all cheap.

Nothing here disputes the design (D′, the dual-lock decision, or the AC6 metric tradeoff). H-1 is a
*scoping* bug inside the accepted dual-lock decision, not a challenge to it.
