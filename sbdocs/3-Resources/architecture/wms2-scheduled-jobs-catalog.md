---
title: "WMS v2 — Scheduled Jobs Catalog"
type: architecture
status: active
version: v2
scope: scheduled-jobs
owner: Nam Park
created: 2026-04-19
updated: 2026-09-06
last_verified: 2026-09-06
verified_by: "SBDEV-3198 (2026-09-06) — the §1/§2 defects this doc recorded as OPEN are FIXED and merged. All six SchedulingConfiguration jobs re-derived from origin/develop d4a6ab8a: registration methods, entry points, TriggerSpec/TenantSchedule, and the two-key AdvisoryLockService surface read from source; doCalculation confirmed absent from src/main (zero declarations, zero call sites — only javadoc describing its deletion). Deployed build read from GET /api/public/version (develop-d4a6ab8a, drift=false). NOT re-verified this pass: per-job transaction boundaries, the §4 read/write inventories, PgBouncer items in §7, and the §6 summary table. Prior SBDEV-3191 — gating classes re-derived from origin/develop daae54a6 (git grep @Scheduled + ConditionalOnProperty over src/main); tenant schedule/timezone syspropse and landlord active-tenant counts captured live via psql against dev/uat/prd. NOT re-verified: per-job transaction boundaries, the §4 read/write inventories, PgBouncer items in §7."
related:
  - ./wms2-transaction-osiv-boundary-map.md
  - ./wms2-state-machine-catalog.md
  - ./wms2-tenant-routing-datasource-topology.md
  - ../../1-Projects/wms2/plan/260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md
  - ../../4-Archieves/wms2/plan/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md
  - ../../4-Archieves/wms2/plan/260331-cron-job-autoflush-optimistic-lock-debug-plan.md
  - ../../4-Archieves/wms2/plan/260424-connection-pool-exhaustion-fix-plan.md
tags:
  - architecture
  - scheduled-jobs
  - cron
  - advisory-lock
  - wms2
---

# WMS v2 — Scheduled Jobs Catalog

**Scope:** Every `@Scheduled` method and business cron job in `v2/wms2-api` · **Version:** v2
**Owner:** Nam Park · **Last verified:** see the frontmatter `last_verified` — it is the single source of truth. (This line asserted `2026-05-08` while the frontmatter said `2026-09-06`; a hand-maintained duplicate of a frontmatter field will always drift, so it is no longer duplicated here.)

---

## 1. Overview

`wms2-api` runs **ten** recurring workloads in-process, in **three** gating classes — corrected 2026-09-02 (SBDEV-3191); the previous "nine … seven business cron jobs gated by `app.cron=true`" was wrong on both the count and the gating:

- **Six** business jobs registered as `CronTrigger`s by `SchedulingConfiguration` — the only class carrying `@ConditionalOnProperty(name = "app.cron", havingValue = "true")`, so these are the only workloads `app.cron` actually gates: `OrderReleaseJob`, `ReplenishOrderJob`, `StockSummaryExportJob`, `CleanUpOldMessagesJob`, `ReleaseExpiredPickingOrdersFromUserJob`, `StaleClubBatchCleanupJob` (SBDEV-2164).
- **Two** business `@Scheduled` jobs that are **NOT gated by `app.cron`** and therefore run on **every replica**: `OutboxDispatcherJob` (SBDEV-2221) and `RestIdempotencyCleanupJob` (SBDEV-2222). Both are plain `@Service` classes with no `@ConditionalOnProperty`; their advisory locks — not `app.cron` — are what keeps them from double-dispatching. See §7.7.
- **Two** infrastructure `@Scheduled` methods that always run: `TenantConfigLoader.scheduledRefresh`, `TenantPoolEvictor`.

Derivation: `git grep -n '@Scheduled' -- src/main` (four real method-level hits; the two further hits in `SchedulingEnablementConfig` and `SchedulingConfiguration` are prose inside javadoc) cross-checked against `git grep -l ConditionalOnProperty -- src/main` filtered for `app.cron`, which returns `SchedulingConfiguration` and nothing else. Blind spot: this counts annotation sites, so a job registered programmatically on the `TaskScheduler` outside `SchedulingConfiguration` would not appear. Cross-replica mutual exclusion for the business jobs is enforced by PostgreSQL **advisory locks** (`pg_try_advisory_lock`), each job holding a fixed integer lock ID for the duration of its run. Tenant context is set manually inside every business job — scheduler threads do not inherit ThreadLocal from the request path.

Three load-bearing facts:

1. **Advisory locks are session-level and will break under PgBouncer transaction pooling.** Every business job will lose mutual exclusion across replicas if PgBouncer is introduced in `pool_mode=transaction` without a lock-strategy change. See §7.
2. **Six of the eight business jobs are off by default.** `app.cron=false` in `application.properties` (grep the key — this citation carried a line number twice, `:111` then `:139`, and was stale both times; SBDEV-3191's own added properties shifted it). ⚠ The two `@Scheduled` business jobs ignore this flag entirely, so "business jobs are off by default" is only true of the `SchedulingConfiguration` six. Infrastructure jobs (`TenantConfigLoader`, `TenantPoolEvictor`) run regardless — they are wired from a separate config class.
   ⚠ **Six jobs, but no longer six triggers.** Since SBDEV-3198 (2026-09-03) `configureAllTasks` registers **five *grouped* jobs plus one single-trigger job** — a grouped job registers one `CronTrigger` per distinct firing specification across the active tenants, so the trigger count is data-dependent and changes on onboarding, deactivation or a timer-sysprop edit. Any statement of the form "there are six triggers" is now wrong; count the registry (`registeredSpecs()`), not the jobs.
3. **One scheduler, pool size 10.** `ThreadPoolTaskScheduler` with a single pool handles business + infrastructure jobs. No `TaskDecorator` is registered, so tenant context is NEVER automatic on scheduler threads. Every business job sets/clears `TenantContext` manually inside its per-tenant loop.

---

## 2. Advisory Lock IDs

Defined in `net/aim_ai/wms/service/AdvisoryLockService.java`, in the nested `public static final class JobLockId`. These integers are the cross-replica mutex keys. Never reuse, never change — a change is a silent breaker because replicas on old code will hold the old ID.

⚠️ **The rule above has a loophole, documented here 2026-09-02 during the SBDEV-3198 design and acted on in the shipped fix.** "Never change the ID" reads as satisfied by *keeping* the number and switching to PostgreSQL's two-argument form — `pg_try_advisory_lock(100008, 2)` instead of `pg_try_advisory_lock(100008)`. It is not. **The one-key and two-key advisory lock spaces are disjoint**: a one-key lock does not block a two-key lock on the same number, so switching form has exactly the same silent-breaker effect as renumbering. State the rule as: *never change the ID **or the lock form** — the (form, key) pair is the mutex identity.*

**✅ Done as prescribed (SBDEV-3198, merged 2026-09-03).** `AdvisoryLockService` now carries **both forms side by side** — read them from source, do not infer from a call site:

| Method | Line | Used by |
|---|---|---|
| `boolean tryLock(long lockId)` | `:76` | **four** lock ids — `100007L`, `100008L`, **and** `100003L`/`100004L` as the outer half of a dual lock (below) |
| `void unlock(long lockId)` | `:115` | same four |
| `boolean tryLock(long jobLockId, long tenantDbConfigurationId)` | `:179` | all six gated jobs, one lock per tenant per occurrence |
| `void unlock(long jobLockId, long tenantDbConfigurationId)` | `:215` | all six gated jobs |

⚠️ **The one-key form did NOT become outbox/idempotency-only, and this is the single most missable fact in §2.** Two of the six converted jobs hold **both** forms — a *dual lock* — and four do not. Derived from the only one-key call sites in `src/main`:

| Job | Lock shape | Call sites |
|---|---|---|
| `CleanUpOldMessagesJob` | **dual** — one-key *per tenant*, wrapping the two-key | one-key `:207`/`:250`, two-key `:220`/`:343` |
| `StockSummaryExportJob` | **dual** | one-key `:266`/`:310`, two-key `:280`/`:395` |
| `OrderReleaseJob` | two-key only | `:221`/`:314` |
| `ReplenishOrderJob` | two-key only | `:283`/`:385` |
| `ReleaseExpiredPickingOrdersFromUserJob` | two-key only | `:195`/`:297` |
| `StaleClubBatchCleanupJob` | two-key only | `:190` |
| `RestIdempotencyCleanupJob` | one-key only | `:50`/`:78` |
| `OutboxDispatcherJob` | one-key only | `:59`/`:110` |

**Why two jobs and not six.** The two lock spaces are disjoint — that is §2's whole rule — so during a **mixed-version window** an old-code replica holding the fleet-wide one-key does not block a new-code replica's two-key, and the job can run twice. PR #288 added the one-key wrapper to `StockSummaryExportJob` for exactly that window (`:262`, review finding H-1) and PR #291 cloned it into `CleanUpOldMessagesJob`; the code names the state the *"dual-lock transitional window"* (`StockSummaryExportJob:272`). Three of the other four state the verdict explicitly — `OrderReleaseJob:44-55`, `ReplenishOrderJob:42`, and `ReleaseExpiredPickingOrdersFromUserJob:24`/`:31`/`:87` all say **"No dual-lock mitigation needed"** and reason it out from their own write paths. ⚠ **`StaleClubBatchCleanupJob` is the exception and its reason is different and stronger:** the word "dual" does not appear in that file at all. Its javadoc `:24-28` records that — measured 2026-09-02 — `STALE_CLUB_BATCH_CLEANUP_ACTIVATED` is `false` on **every UAT tenant and on prd hydra**, so the job is **inert everywhere** and the conversion changed no live behaviour. Both dual-lock siblings cite that inertness as the contrast. The distinction matters: "inert" means there is nothing to back-fill, whereas "it predates the mechanism" would imply an oversight someone should go and fix. **So read the specific job's javadoc before changing its lock shape — four of the six record a decision, and the fifth records an absence of exposure.**

⚠️ **The dual lock is declared TEMPORARY by the code that added it, and this doc is not its owner.** `StockSummaryExportJob:57-58`: *"This is a ONE-RELEASE transitional shape; the one-key acquisition is deleted in the following release once every replica is converted."* So the §2 table above describes **current state with a stated expiry**, not a design. Two consequences: whoever ships the next release should delete the one-key half in both jobs (and update this table), and nobody should copy the dual lock into a new job as if it were the house pattern. Note also that PR #288's H-1 finding **re-scoped** an already-decided mitigation from group-wide to per-tenant (`:47`, `:54-57`) rather than introducing it — the group-wide version would have let one busy old-code replica starve an entire group for a whole occurrence and held two JDBC connections open for the whole walk.

⚠️ It is acquired **per tenant, sequentially** — take one-key, take two-key, work, release two-key, release one-key. A busy one-key therefore costs *one tenant* this occurrence rather than the whole group, but it does mean **tenants of these two jobs still serialise against each other fleet-wide**. A one-key `tryLock` returning `false` is also **not diagnostic**: `AdvisoryLockService.tryLock` catches `SQLException` and returns `false` identically for "an old-code replica holds it" and "the landlord pool is exhausted", which is why the WARN at `:212`/`:272` names both causes and asserts neither.

`100007L` and `100008L` stayed on the one-key form deliberately, and **AC5a pins that with a test** (`AdvisoryLockServicePerTenantLockUnitTest`) precisely so a later "tidy up the remaining one-key call sites" refactor cannot silently migrate them. The reason to leave them is *not* the OMS double-send one this doc used to give — `OutboxDispatcherJob`'s `findAndClaimPending` already uses `FOR UPDATE SKIP LOCKED` with an atomic status flip, so a second dispatcher cannot double-claim. The real reason is narrower: those two jobs are correct as-is and were out of scope; the cost of losing their guard is a doubled OMS **request rate** and a ~5-minute re-send window, not a double-send.

⚠️ **The claim in the paragraph this replaced is TRUE for dev and UAT and FALSE for prd — it is not simply "wrong", and an earlier version of this rewrite got that wrong in the safe-sounding direction.** It said *"each environment deploys `wms-api` and `cron` via two independent Portainer webhooks with nothing sequencing them, so a mixed-version window is entered on every deploy."* Re-derived from the workflows at `d4a6ab8a`:

| Env | Workflow | Webhooks |
|---|---|---|
| **dev** | `.github/workflows/docker-image-develop.yml:45-46` | **two live sequential `curl` calls**, nothing sequencing container readiness |
| **UAT** | `.github/workflows/docker-image-uat.yml:133-134` | **two live sequential `curl` calls**, same shape |
| **prd** | `.github/workflows/docker-image.yml:77` (runs on `main`) | **one**, and it is **commented out** |

So the mixed-version window is **measured-present on dev and UAT** — the two environments where the dual-lock path above actually gets exercised — and absent on prd, where deploys are **recreate**. On prd the six gated jobs are unexposed **provided exactly one container carries `app.cron=true`**, which is a Portainer fact nobody has confirmed (SBDEV-3198 AC5, still open). Do **not** read this as "the hazard is probably absent": it is present where you test and unverified where you ship.

The lock key deliberately contains **no group-membership-derived component** — not a membership hash, not a group ordinal. Both were proposed in rev 1 of the SBDEV-3198 design and both are unsound: a hash is content-addressed on a tenant set that changes on onboarding/deactivation/sysprop-edit, so two JVMs compute different keys for overlapping work and both acquire; an ordinal is worse, since the same key can cover different tenant sets and one set goes silently unprocessed. **AC12 pins this.** The second key is always `tenant_db_configuration.id`.

| Constant | Value | Job |
|---|---|---|
| `JobLockId.ORDER_RELEASE` | `100001L` | `OrderReleaseJob` |
| `JobLockId.REPLENISH_ORDER` | `100002L` | `ReplenishOrderJob` |
| `JobLockId.CLEAN_UP_MESSAGES` | `100003L` | `CleanUpOldMessagesJob` |
| `JobLockId.STOCK_SUMMARY_EXPORT` | `100004L` | `StockSummaryExportJob` |
| `JobLockId.RELEASE_EXPIRED_PICKING` | `100005L` | `ReleaseExpiredPickingOrdersFromUserJob` |
| `JobLockId.STALE_CLUB_BATCH_CLEANUP` | `100006L` | `StaleClubBatchCleanupJob` (SBDEV-2164) |
| `JobLockId.CLEANUP_REST_IDEMPOTENCY` | `100007L` | `RestIdempotencyCleanupJob` (SBDEV-2222) |
| `JobLockId.OUTBOX_DISPATCHER` | `100008L` | `OutboxDispatcherJob` (SBDEV-2221) |

Infrastructure jobs (`TenantConfigLoader`, `TenantPoolEvictor`) do **not** take advisory locks — they are idempotent cache refreshers and safe to run concurrently on every replica.

---

## 3. Scheduling Infrastructure

⚠ **Line cites in this doc's §3 and §4 have gone stale three times** (§1 fact 2 records two of them for `app.cron` alone). Where a cite below was re-derived on 2026-09-06 it names the SHA; where it was found pointing at unrelated code it has been **replaced by a symbol name**, deliberately, because the symbol survives a refactor and the number does not.

### 3.1 Enablement split

Two `@Configuration` classes deliberately separate "always-on" scheduling from "business" scheduling:

| File | Role | Gate |
|---|---|---|
| `config/SchedulingEnablementConfig.java` | `@EnableScheduling` — activates `@Scheduled` annotation processing everywhere | unconditional |
| `schedulejob/SchedulingConfiguration.java` | Registers business cron jobs on `TaskScheduler` with `CronTrigger`s | `@ConditionalOnProperty(name = "app.cron", havingValue = "true")` |

Consequence: `TenantConfigLoader` and `TenantPoolEvictor` always run. `OrderReleaseJob` etc. require `app.cron=true` **and** the per-job activation sysprop.

### 3.2 `TaskScheduler` bean

`SchedulingConfiguration.taskScheduler()` — `@Bean` at `:230`, method body `:232-239` at `d4a6ab8a` (this cite read `:69-78`, which is now the `CRON_SCHEDULE_ZONE` region):

```java
@Bean @Primary
public TaskScheduler taskScheduler() {
    ThreadPoolTaskScheduler scheduler = new ThreadPoolTaskScheduler();
    scheduler.setPoolSize(POOL_SIZE);           // 10
    scheduler.setThreadNamePrefix("scheduled-task-pool-");
    scheduler.setWaitForTasksToCompleteOnShutdown(true);
    scheduler.setAwaitTerminationSeconds(60);
    return scheduler;
}
```

- **Pool size: 10** (hard-coded at `SchedulingConfiguration.java:30`). Shared across business + infrastructure jobs. If a long-running job hogs a thread, other schedules wait.
- **No `TaskDecorator`.** See §6 of [wms2-tenant-routing-datasource-topology.md](./wms2-tenant-routing-datasource-topology.md) — `TenantAwareTaskDecorator` exists but is never wired. Every business job compensates by setting `TenantContext` manually.
- **60-second drain on shutdown.** Running jobs get up to a minute; after that, kill.

### 3.3 Startup gate

`SchedulingConfiguration.onApplicationReady()` (`@EventListener(ApplicationReadyEvent.class)` at `:241`, method `:243`, body running to `:393` at `d4a6ab8a` — this cite read `lines 80–114`) defers business-job wiring until tenant DBs are reachable:

1. Waits 5 s after `ApplicationReadyEvent` before polling.
2. ⚠ **`isTenantDatabaseInitialized()` no longer exists** — verified: zero hits in `src/main`, positive control `awaitReachableTenantAndConfigure` returns 2. SBDEV-3191 Slice A and SBDEV-3204 replaced it with `awaitReachableTenantAndConfigure` (`:394`) plus `probeForReachableTenant` (`:533`). The 60-attempt / 1000 ms figures are no longer hard-coded either: they are `@Value` defaults (`:46-50`, `wms.scheduling.boot-probe.max-attempts:60` and `retry-delay-ms:1000`), clamped at `:403-404`. The 5 s wait after `ApplicationReadyEvent` is real (`:283`, `+ 5000`). See §7.10 for why the probe terminates rather than hanging.
3. Each poll sets a tenant context, calls `tenantDynamicRoutingDataSource.determineTargetDataSource()` to trigger pool creation, then clears the context — `probeForReachableTenant`, `:566`/`:569`/`:584` at `d4a6ab8a` (these cites read `lines 135, 137, 143`).
4. Once connected, configures **all six** business cron jobs — `configureAllTasks` (`:629`/`:640`), called from `:439`. ("five" and `line 100` were both wrong.) If the attempts are exhausted, business jobs are never wired on this replica. ⚠ Since SBDEV-3198 registration is **converging and additive-only** (AC10/AC14/AC15, PR #283) and reconciles later, so "never wired" is no longer the only outcome of a slow tenant — see §7.10.

### 3.4 Global gates (sysprops in the **TENANT** DB)

⚠️ **Corrected 2026-09-06: this heading said "landlord DB" and was wrong — and it contradicted §7.8 of this same doc, which is the entire premise of the defect §7.8 documents.** `Sysprop` is `@Table(name = "los_sysprop")` (`model/Sysprop.java:10`) and `SyspropService` runs on `@Transactional(value = "tenantTransactionManager")` with a `TenantContext`-keyed cache — so **every sysprop below is per-tenant, read from whichever tenant DB the current `TenantContext` routes to.** That is exactly why one arbitrary tenant's `TenantContext` at registration time could set the schedule for the whole fleet (§7.8), and why the D′ fix has to re-derive each tenant's spec under its own context. `app.cron` is the only genuinely process-wide gate here, because it is a Spring property in `application.properties`, not a sysprop.

| Key | Default | Role |
|---|---|---|
| `app.cron` (in `application.properties`) | `false` | Class-level gate on `SchedulingConfiguration` — **the only class carrying it** |
| `NEW_CRON_JOB_ACTIVATED_KEY` | `true` | Per-job top-level gate, checked inside each job method |
| `CRON_JOB_SHOW_LOG_KEY` | `false` | Verbose debug logging across all business jobs |

Every business job also reads its own `*_ACTIVATED_KEY` before doing work. Turning `app.cron=true` alone does not start any job — each needs its own activation flag too.

---

## 4. Business Cron Jobs

⚠️ **This section's shared shape changed wholesale in SBDEV-3198 (merged 2026-09-03).** The pre-D′ shape below is retained only to make older plans and reports readable — **it is not what the code does.** Note also "all five": there are **six** `SchedulingConfiguration` jobs, and that miscount predates this pass.

<details>
<summary>Pre-D′ shape (historical — one process-wide lock, one trigger per job)</summary>

```java
if (!globallyActivated || !thisJobActivated) return;
if (!advisoryLockService.tryLock(JobLockId.X)) {     // one lock for the whole FLEET
    LOG.info("...already running on another replica, skipping");
    return;
}
try {
    for (TenantProfile profile : allTenants) {
        TenantContext.setCurrentTenant(profile);
        try { /* per-tenant work */ }
        catch (Exception e) { LOG.error(...); /* continue */ }
        finally { TenantContext.clear(); }
    }
} finally {
    advisoryLockService.unlock(JobLockId.X);
}
```
</details>

**Current shape — Option D′, grouped by firing specification.** `doCalculation(Boolean isCronJob)` **no longer exists anywhere in `src/main`** (verified: zero declarations, zero call sites; the only remaining mentions are javadoc describing its removal). It was replaced by up to three entry points — ⚠ **all three exist on only four of the six jobs**, and the two exceptions are exactly the jobs whose shape differs:

| Job | `deriveSpecForCurrentTenant` | `runFor` | `runForCurrentTenant` |
|---|---|---|---|
| `OrderReleaseJob` | `:146` | `:169` `(TriggerSpec)` | `:292` |
| `ReplenishOrderJob` | `:202` | `:225` `(TriggerSpec)` | `:357` |
| `StockSummaryExportJob` | `:171` | `:199` `(TriggerSpec)` | `:373` |
| `CleanUpOldMessagesJob` | `:134` | `:155` `(TriggerSpec)` | `:321` |
| `ReleaseExpiredPickingOrdersFromUserJob` | **absent** | `:143` — **no-arg `runFor()`** | `:275` |
| `StaleClubBatchCleanupJob` | `:100` | `:133` `(TriggerSpec)` | **absent** |

`ReleaseExpiredPickingOrdersFromUserJob` has no spec to derive (hard-coded cron, single trigger) and `StaleClubBatchCleanupJob` has no manual-trigger endpoint, so `runForCurrentTenant` has **five** declarations in `src/main`, not six. The generic contract:

| Entry point | Purpose |
|---|---|
| `TenantSchedule deriveSpecForCurrentTenant()` | package-private; reads **this** tenant's `*_TIMER_*` sysprops and IANA zone under a `TenantContext` the caller must have set. Throws if the context is unset — it never guesses a tenant. |
| `void runFor(TriggerSpec spec)` | the scheduled path. Walks every active tenant, re-derives each one's spec at **fire time**, and processes only those whose spec equals `spec`. |
| `boolean runForCurrentTenant()` | the manual/admin path, one tenant, returning whether it actually ran. Replaces `doCalculation(false)`. ⚠ There are **two** non-scheduler callers, not one — `AdminActionController` and, for `StockSummaryExportJob` only, `StockCountRestController:111` on the internal `/rest/**` surface (`StockSummaryExportJob:59` names both). The REST one is documented in [wms2-rest-api-reference.md](../design/wms2-rest-api-reference.md) §5.2, including the fact that it returns HTTP 200 whether the job ran or refused. |

```java
// runFor(spec) — the scheduled path, per tenant. Abridged from StaleClubBatchCleanupJob:133.
for (TenantDbConfiguration config : tenantDbConfigurationRepository.findByActiveTrue()) {
    TenantContext.setCurrentTenant(new TenantProfile(config.getTenant().getName(), config.getWarehouse()));
    try {
        TenantSchedule own = deriveSpecForCurrentTenant();
        if (own == null || !own.spec().equals(spec)) continue;   // not a member of THIS group
        // tenant_db_configuration.id must narrow to int4 or the tenant cannot be locked at all
        if (!advisoryLockService.tryLock(JobLockId.X, config.getId())) continue;  // TWO-key
        try { /* per-tenant work */ }
        finally { advisoryLockService.unlock(JobLockId.X, config.getId()); }
    } finally { TenantContext.clear(); }
}
```

Four consequences worth knowing before you touch any of this:

- **Group membership is re-derived every occurrence, never frozen at registration.** A trigger carries a `TriggerSpec`, not a tenant list, so activation/deactivation and sysprop edits take effect on the next tick (AC11).
- **The lock is per `(job, tenant)`** — for four of the six jobs. Tenants that co-fire no longer serialise and N−1 no longer skip silently at DEBUG (AC4). ⚠ **`CleanUpOldMessagesJob` and `StockSummaryExportJob` are the exceptions**: they wrap the two-key in a per-tenant *one-key* lock as a mixed-version guard, so their tenants still serialise against each other fleet-wide. See §2's lock-shape table — do not generalise from one job to the six.
- **A tenant whose `tenant_db_configuration.id` does not narrow to `int4` cannot be locked** under the two-key form and is skipped **every** occurrence, with an ERROR naming the id. There is no fallback to the one-key form.
- **The five untagged whole-run `JobMetrics`** (`markLastSuccess`, `markLastRun`, `recordDuration`, `skippedLockBusy`, `skippedJvmBusy`) are per-*group*, not per-fleet, so a gauge going green means *some* group succeeded (AC6). Do not build fleet-health alerting on them without reading `WholeRunSuccessGaugeUnitTest` first. ⚠ And one of the five is not per-group either: **`skippedLockBusy` is recorded once per lock-busy MEMBER TENANT**, so a two-tenant group where both find the one-key busy records `2.0` (`CleanUpOldMessagesJob:73-76`, pinned by `CleanUpOldMessagesJobMetricsUnitTest.tryLockBusy_twoTenantGroup_incrementsSkippedLockBusyPerTenant`).

### 4.0 `TriggerSpec` and `TenantSchedule` — the D′ abstractions

Two records added by SBDEV-3198, in `net/aim_ai/wms/schedulejob/`:

```java
public record TriggerSpec(String cronExpression, String zoneId)      // TriggerSpec.java
public record TenantSchedule(TriggerSpec spec, ZoneId resolvedZone)  // TenantSchedule.java
```

`TriggerSpec` is the **grouping key**: two tenants share a trigger exactly when their specs are equal. Three things about it are easy to get wrong:

- **`zoneId` is a `String`, not a `ZoneId`,** so that the record's `equals` (and therefore group identity) is a value comparison rather than a `ZoneId` identity question.
- **Zone-invariant crons collapse.** `TriggerSpec.of(cron, zone)` stores the sentinel `"zone-invariant"` in place of the real zone when `isZoneInvariant(cron)` holds — that is — in `TriggerSpec`'s own words at `:61-62` — when **minute, hour, day-of-month, month and day-of-week are ALL `*`, so only the seconds field may be fixed**, and the expression therefore fires at identical instants in every zone (the loop is `for (int i = 1; i < 6; i++)` over **0-indexed** fields, which reads as "fields 1–5" only if you are already thinking 0-indexed — state it in field names, not indices). Without this, a per-minute cron would fan out into one trigger per distinct tenant zone: five triggers where three suffice. `zoneForTrigger()` maps the sentinel back to UTC.
- **A malformed expression is not zone-invariant.** `isZoneInvariant` requires exactly 6 whitespace-separated fields and returns `false` otherwise, so a bad cron groups by real zone rather than collapsing.

`TenantSchedule` pairs the spec with the zone actually resolved for that tenant, which is what lets the registration provenance line name a tenant that **fell back to UTC** rather than silently grouping it with genuine UTC tenants (AC2′).

### 4.1 `OrderReleaseJob`

| | |
|---|---|
| **File** | `schedulejob/OrderReleaseJob.java` |
| **Wired** | `SchedulingConfiguration.configureOrderReleaseGroups()` — **grouped**. `:835` at `d4a6ab8a`; this row's line cite has gone stale twice, re-derive with `git grep -n 'configureOrderReleaseGroups'` |
| **Lock ID** | `JobLockId.ORDER_RELEASE` (100001L) |
| **Cron** | `0 {ORDER_TIMER_MINUTE} {ORDER_TIMER_HOUR} * * *` (defaults `*`/`*` → every minute) |
| **Activation sysprop** | `ORDER_TIMER_ACTIVATED_KEY` (default `true`) |
| **Tunables** | `FIX_LOCATION_PAGE_SIZE` (default 2000), `FIX_LOCATION_PAGE_LIMIT` (default 100) — cap fix-location prefetch pages per run |
| **Reads** | **SBDEV-2228 Fix A:** stream-cursored `customerorderposition` via `ReleaseOrderJobService.streamOrderPositionsForEach(readOnly=true)` — replaces unbounded `List<OrderReleaseInfoView>` + in-heap bucketing. `@QueryHints(fetchSize=500)`, `ORDER BY co.prio DESC, co.created ASC, co.id ASC, cop.number ASC`. `fixlocationassignment` prefetched via `FIX_LOCATION_PAGE_LIMIT` pages of `FIX_LOCATION_PAGE_SIZE`; warehouse TZ sysprop. |
| **Writes** | `customerorder` state transitions; `pickingorder` rows (creation); `customerorderposition` state |
| **Per-step TX** | Outer cursor via `ReleaseOrderJobService.streamOrderPositionsForEach(@Transactional readOnly=true)` — SBDEV-2228 Fix A keeps JDBC cursor alive. Per-order commits via `releaseOrder(REQUIRES_NEW)` suspend the outer tx; one TX per order. |
| **Error resilience** | Per-order try-catch (`OptimisticLockException` / `FacadeException` / `BusinessException`) inside the release loop — one order failure does not abort the run. (Cite was `line 286`, which is javadoc prose inside `runForCurrentTenant`.) |

**Work:** Walks all `ASSIGNED` customer order positions grouped by customer order, evaluates fixed-location and overstock availability per item, and releases orders that can now be fulfilled. This is the hottest transaction site in the app — ~70 setState calls across hold/release logic. See §7 of [wms2-state-machine-catalog.md](./wms2-state-machine-catalog.md) for the state transitions fired here.

### 4.2 `ReplenishOrderJob`

| | |
|---|---|
| **File** | `schedulejob/ReplenishOrderJob.java` |
| **Wired** | `SchedulingConfiguration.configureReplenishGroups()` — **grouped**. `:943` at `d4a6ab8a` |
| **Lock ID** | `JobLockId.REPLENISH_ORDER` (100002L) |
| **Extra guard** | JVM-local `AtomicBoolean RUNNING` — **unique among the six, and deliberately kept through the D′ conversion** (PR #304). ⚠ Not a correctness guard, despite what this row used to say: it is a **resource throttle**. This is the largest job body in the subsystem (nine sequential bulk operations per tenant, six of which page), and the guard is shared between `runFor()` and `runForCurrentTenant()`, matching its pre-D′ scope exactly. Correctness comes from the two-key advisory lock plus per-row optimistic locking |
| **Cron** | `20 {REPLENISHMENT_TIMER_MINUTE} {REPLENISHMENT_TIMER_HOUR} * * *` (defaults `*`/`*` → every minute at :20) |
| **Activation sysprop** | `REPLENISHMENT_TIMER_ACTIVATED_KEY` |
| **Sub-feature gates** | `MERGE_PICKING_ORDERS_KEY`, `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY_KEY` (sic — typo preserved in code) |
| **Tunables** | `PICKING_BOX_PER_CART_KEY`, `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_KEY`, `REPLENISHMENT_PAGE_SIZE` (default 1000), `REPLENISHMENT_PAGE_LIMIT` (default 100) |

**Nine sub-operations per run** (⚠ this heading read "Six" — a pre-existing miscount, corrected 2026-09-06; `ReplenishOrderJob:413`'s own javadoc says "nine-operation sequence" and `replenish(:415-463)` makes exactly nine sub-op calls. Note `wms2-replenishment-design.md` §8's phase table has **10** rows because it counts the `ReplenishmentOrderMaintenanceService` block as a phase — both conventions are defensible, so say which you mean):**

1. `mergePickingOrders()` — merge totes-on-cart picking orders (gated on `MERGE_PICKING_ORDERS_KEY`)
2. `deleteEmptyFixAssignmentWithoutStockToReplenish()` — clean up empty fixed locations
3. `cancelUnreachableReplenishment()` — cancel orders for unreachable locations
4. `cancelReplenishmentIfFlowbinIsFull()` — cancel orders if flowbin full
5. `generateReplenishmentForItemDataWithoutFixedAssignment()` — create new replenish orders
6. `generateReplenishmentForItemDataWithFixedAssignmentWithOrders()` — ⚠ **added 2026-09-06: this call was missing from the list entirely**, which is how the heading's "Six" survived. It is the 6th of the nine calls `replenish()` makes
7. `triggerRegularReplenishment()` — refill
8. `updateReplenishmentOrderPriority()` — re-prioritise
9. `recalculateReplenishmentOrderWithoutFixedLocationAssignment()` — recalc open orders

**Per-step TX** — all inner service methods are `@Transactional(value="tenantTransactionManager", propagation=REQUIRES_NEW)`. **SBDEV-2228 Fix B:** drain-queue pagination (`PageRequest.of(0, pageSize)` — always page 0) including `updateReplenishmentOrderPriority` ⚠ — but **6 of the 9 calls page, not all of them**: `triggerRegularReplenishment` iterates `getRefillFixedLocationIds()` unbounded and `recalculateReplenishmentOrderWithoutFixedLocationAssignment` has no loop at all (re-derived 2026-09-06; "each of the 6 sub-ops" was counting the old 6-item list, not the nine calls): the query hardcodes `AND replenishmentOrder.prio != 0` so processed rows leave the result set, making drain-queue safe. Sub-op page size / limit controlled by `REPLENISHMENT_PAGE_SIZE` / `REPLENISHMENT_PAGE_LIMIT` sysprops. See §7 of [wms2-transaction-osiv-boundary-map.md](./wms2-transaction-osiv-boundary-map.md) — this job remains the dominant driver of per-tenant connection-pool pressure during replenish bursts.

**Error resilience** — per-item try-catch for `OptimisticLockException` / `OptimisticLockingFailureException` / generic `Exception` in 8 of the 9 private write methods, plus a per-tenant try-catch. (Cites read `lines 155–159, 251–258` and `166–169`; `:150-172` is now the constructor parameter list. Per-method detail, including which method has no catch, is in [wms2-replenishment-design.md](../design/wms2-replenishment-design.md) §8 — kept in one place rather than duplicated as line numbers here.)

### 4.3 `StockSummaryExportJob`

| | |
|---|---|
| **File** | `schedulejob/StockSummaryExportJob.java` |
| **Wired** | `SchedulingConfiguration.configureStockSummaryExportGroups()` — **grouped**. `:1044` at `d4a6ab8a` |
| **Lock ID** | `JobLockId.STOCK_SUMMARY_EXPORT` (100004L) |
| **Cron** | `0 {STOCK_SUMMARY_EXPORT_TIMER_MINUTE:0} {STOCK_SUMMARY_EXPORT_TIMER_HOUR:3} * * *` (default 03:00 daily) |
| **Activation sysprop** | `STOCK_SUMMARY_EXPORT_TIMER_ACTIVATED_KEY` |
| **Batching** | Gated on `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED_KEY`, batch size `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_AMOUNT_SKU_PER_BATCH_KEY`. **SBDEV-2219:** when split-flag is OFF, a hard ceiling `STOCK_SUMMARY_EXPORT_NO_SPLIT_MAX_CHUNK = 10_000` (constant, not sysprop) is enforced to prevent O(rows) heap regression — operator-visible `LOG.warn` cites the safety net. |
| **Endpoints** | `WEBSERVICE_STOCK_COUNT_URL_KEY` (OMS stock-count receiver), `WMS_INSTANCE_NAME`, `OMS_INSTANCE_NAME` |
| **Tunables** | `OMS_EXPORT_CONSUMER_TIMEOUT_S` (default 120s) — controls BlockingQueue offer timeout, POISON_PILL drain timeout, and consumer thread join deadline. **SBDEV-2228 Fix C:** OMS HTTP POSTs run in a daemon consumer thread decoupled from the Hibernate cursor; this sysprop is the single knob for all three bounded-wait operations. |
| **Reads** | **SBDEV-2219:** stream-cursored `stockcount` via `warehouseStockReportService.streamStockCount(Consumer<StockCountDto>)`. Replaces the legacy `getStockCount()` (now a `@Deprecated` shim that throws `UnsupportedOperationException`). The streaming path is wrapped in `@Transactional(value="tenantTransactionManager", readOnly=true)` and uses `Stream<StockView>` with `@QueryHints(HINT_FETCH_SIZE=500)` + `try-with-resources` close semantics. Hard cap: `count()` first; throws `BusinessException("BusinessException.StockCountTooLarge")` if `> SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS_KEY` (default 1,000,000) and increments Micrometer counter `stock_summary_export_aborted_total`. |
| **Rollback toggle** | **SBDEV-2219:** `STOCK_SUMMARY_EXPORT_STREAMING_ENABLED_KEY` (default `true`). When `false`, `streamStockCount` delegates to a private `legacyGetStockCount()` bridge that calls the original unbounded `findAll()` — preserved as an emergency rollback only; the public no-arg method is hard-fail. |
| **Writes** | `inventoryrecord` (one row per batch) via `inventoryRecordService.createEntitiesBulk(REQUIRES_NEW)` — **SBDEV-2228 Fix C:** replaces per-row `createEntity`. `InventoryRecord` objects buffered inside the stream lambda; bulk-insert triggered at `batchSize` boundary. OMS HTTP POSTs (`sendList`) deferred until AFTER `streamStockCount` returns (cursor tx committed, DB connection released). `message` / `message_archive` (audit); `messageService.createMessage` failures wrapped locally per SBDEV-2217. |
| **Per-step TX** | No job-level `@Transactional`; bulk record creation uses `REQUIRES_NEW` (escapes outer `readOnly=true`); cursor tx closes before OMS HTTP calls (SBDEV-2228 Fix C). |
| **Error resilience** | Per-tenant `catch (Exception e)` inside `runFor`'s tenant loop (cite `lines 102–103` was the `@Service`/class declaration — grep the method, not a line); HTTP `IOException` caught and logged as HTTP-503 in `message`; **SBDEV-2219:** `BusinessException` from cap-trip is caught at the per-tenant boundary so one tenant's runaway data does not abort other-tenant exports |

### 4.4 `CleanUpOldMessagesJob`

| | |
|---|---|
| **File** | `schedulejob/CleanUpOldMessagesJob.java` |
| **Wired** | `SchedulingConfiguration.configureCleanUpOldMessagesGroups()` — **grouped**. `:720` at `d4a6ab8a` |
| **Lock ID** | `JobLockId.CLEAN_UP_MESSAGES` (100003L) |
| **Cron** | `0 {CLEAN_UP_OLD_MESSAGES_TIMER_MINUTE:55} {CLEAN_UP_OLD_MESSAGES_TIMER_HOUR:2} * * *` (default 02:55 daily) |
| **Activation sysprop** | `CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY` (default **`false`** — the only business job off by default beyond the global gate) |
| **Retention** | `CLEAN_UP_OLD_MESSAGES_PERIOD_KEY` — days. Parsed via `Integer.parseInt`; malformed value surfaces as `BusinessException.INVALID_SYSPROP_VALUE` (SBDEV-2220 — replaces raw `NumberFormatException`); `null`/blank falls back to default. |
| **Batch cap** | `CLEAN_UP_OLD_MESSAGES_BATCH_SIZE_KEY` — DELETE batch size, default 1000, clamped to [1, 100000] (SBDEV-2220). |
| **Throttle** | `CLEAN_UP_OLD_MESSAGES_BATCH_SLEEP_MS_KEY` — optional inter-batch sleep in ms, default 0 (off), clamped to [0, 5000]. Injected via `Sleeper` functional interface (`service/job/Sleeper.java` + `MessageCleanupConfig.java`) for unit-test substitution (SBDEV-2220). |
| **Reads** | `message` rows older than `today - period_days` |
| **Writes** | `message_archive` (archive via `messageCleanupBatchService.archiveOnce(refDate)`), then batched delete via `messageCleanupBatchService.deleteOnce(refDate, batchSize)` until returned count < batchSize. |
| **Per-step TX** | **Per-batch `REQUIRES_NEW` on tenant TM** (SBDEV-2220) — `MessageCleanupBatchService.{archiveOnce, deleteOnce}` are annotated `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW, rollbackFor = BusinessException.class)`. Each batch commits independently; a failure mid-loop leaves prior batches durable. Replaces the prior pattern of bare `@Transactional` on `MessageRepository` methods (which silently bound to the landlord TM). |
| **HAL exposure** | `MessageRepository.{archiveMessages, deleteMessages}` are now `@RestResource(exported = false)` (SBDEV-2220) — previously exposed as `POST /api/message/search/{archiveMessages, deleteMessages}` with no auth check beyond tenant JWT. |
| **Error resilience** | Per-tenant `catch (Exception e)` inside `runFor`'s tenant loop (cite `lines 72–74` was class javadoc); `BusinessException` from a malformed sysprop on one tenant is logged and the next tenant proceeds. |

### 4.5 `ReleaseExpiredPickingOrdersFromUserJob`

| | |
|---|---|
| **File** | `schedulejob/ReleaseExpiredPickingOrdersFromUserJob.java` |
| **Wired** | `SchedulingConfiguration.configureReleaseExpiredPickingOrdersFromUser()` — **the one job that is NOT grouped**, a single fleet-wide trigger. `:1142` at `d4a6ab8a`. Its cron is hard-coded `"40 * * * * *"` with no timer sysprop, so there is nothing per-tenant to group on. ⚠ Its **cron** is zone-invariant, but its registered `TriggerSpec.zoneId` is the literal `"America/Los_Angeles"` rather than the `ZONE_INVARIANT` sentinel, because the one-arg `register` bypasses `TriggerSpec.of(...)` — see §7.9 |
| **Lock ID** | `JobLockId.RELEASE_EXPIRED_PICKING` (100005L) |
| **Cron** | **Hard-coded** `40 * * * * *` — every minute at :40 (no sysprop override) |
| **Activation sysprop** | `PICK_TIME_OUT_SYSTEM_ACTIVATED_KEY` (default **`false`**) |
| **Timeout** | `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE_KEY` — seconds, default 40 |
| **Reads** | `pickingorder` rows with `lockedtooperator = true` (⚠ **NOT** `AND operator_id IS NOT NULL` — this doc claimed that until 2026-09-08 and it has been wrong since #285, which deliberately DROPPED that predicate so the job can self-heal an ORPHAN lock: locked with no operator recorded), `pickinginprogress = false` (the collision guard — it predates SBDEV-1675, which added only the two broken lines), `state < PICKED` (so RESERVED/STARTED, **not** PICKED), at least one `pickingorder_position`, section picking type `RAPID_PICKING`, and `modified` older than the threshold. ⚠ **SBDEV-3205 (2026-09-02):** from `326b20dc` (SBDEV-1675, 2025-10-31) until that fix the WHERE clause also demanded `operator_id is null AND lockedtooperator = FALSE` — unsatisfiable against the `lockedtooperator = true` it already carried — so the job selected **0 rows on every tenant on every run**. Pinned by `ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest`. |
| **Writes** | `pickingorder` — clears `operator_id`, sets `lockedtooperator = false` (releases back to pool); `state` is left unchanged. **SBDEV-3262:** each row is now saved inside its own `try`/`catch (ConcurrencyFailureException)`, so one order a picker has concurrently claimed no longer aborts the rest of that tenant's batch — it is counted via `orderSkippedLockContention` and retried next occurrence. If **every** attempted row fails the last failure is rethrown, so a tenant that released nothing still records `tenantFailure` rather than reporting a clean run. Throughput is now recorded via `rowsProcessed`, giving the skip counter a denominator. ⚠ The per-row swallow is sound ONLY because nothing in `schedulejob` is `@Transactional` (each `save` commits inside the call); adding `@Transactional` to this job would silently destroy the isolation. |
| **Per-step TX** | Repository `save()` auto-TX |
| **Error resilience** | Per-tenant `catch (Exception e)` inside `runFor`'s tenant loop (cite `lines 81–85` was class javadoc) |

### 4.6 `StaleClubBatchCleanupJob` (SBDEV-2164)

| | |
|---|---|
| **File** | `schedulejob/StaleClubBatchCleanupJob.java` |
| **Wired** | `SchedulingConfiguration.configureStaleClubBatchCleanupGroups()` — **grouped**; the proof-of-shape conversion (PR #286). `:1193` at `d4a6ab8a` |
| **Lock ID** | `JobLockId.STALE_CLUB_BATCH_CLEANUP` (100006L — added by SBDEV-2164 / commit 57ec70e, port of v1 `b746c39`+`38474e8`) |
| **Cron** | `0 {STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE} {STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR} * * *` — sysprop driven |
| **Activation sysprop** | `STALE_CLUB_BATCH_CLEANUP_ACTIVATED_KEY` (per-job gate) |
| **Reads** | `customerorderbatch` rows representing club batches stale beyond a threshold via `customerorderBatchRepository.findStaleClubBatchIds(...)` |
| **Writes** | Cleanup of stale club batches via `StaleClubBatchCleanupJobService.cleanupStaleBatches()` (delegates per-batch through its own `@Transactional(value="tenantTransactionManager")`); orchestrator itself has no class-level @Transactional |
| **Per-step TX** | Per-batch transaction inside `cleanupStaleBatches()` — opening a fresh TX per stale batch ID |
| **Error resilience** | Per-tenant `catch (Exception e)` with `TenantContext.clear()` in the `finally` of `runFor`'s tenant loop (cite `lines 50–71` was the logger field + constructor) |

---

### 4.7 `RestIdempotencyCleanupJob` (SBDEV-2222)

| | |
|---|---|
| **File** | `schedulejob/RestIdempotencyCleanupJob.java` |
| **Wired** | `@Scheduled(cron = "${app.cron.cleanup-rest-idempotency}")` — Spring `@Value` driven (not a DB sysprop) |
| **Lock ID** | `JobLockId.CLEANUP_REST_IDEMPOTENCY` (100007L — added by SBDEV-2222) |
| **Cron** | `app.cron.cleanup-rest-idempotency=0 0 2 * * *` (hard default: 02:00 daily) |
| **Activation** | **Ungated — nothing switches this job off.** No per-job sysprop, and **NOT** gated by `app.cron`: this is a plain `@Service` with a method-level `@Scheduled`, activated by the unconditional `@EnableScheduling` in `config/SchedulingEnablementConfig.java`, so it fires on **every replica**. `app.cron.cleanup-rest-idempotency` is the **cron expression**, not the boolean gate — see §7.7. (Corrected 2026-09-02, SBDEV-3191.) |
| **Reads** | `rest_idempotency` rows; deletes those with `created_at < NOW() - 7 days` |
| **Writes** | `RestIdempotencyRepository.deleteOlderThan(Instant)` — bulk DELETE via JPQL |
| **Per-step TX** | Single `@Transactional("tenantTransactionManager")` DELETE per tenant — no inner REQUIRES_NEW |
| **Error resilience** | Per-tenant try-catch with `TenantContext.clear()` in `finally`; advisory lock released in outer `finally` |

---

### 4.8 `OutboxDispatcherJob` (SBDEV-2221)

| | |
|---|---|
| **File** | `schedulejob/OutboxDispatcherJob.java` |
| **Wired** | `@Scheduled(cron = "${app.cron.outbox-dispatcher:*/15 * * * * *}")` — Spring `@Value` driven (not a DB sysprop) |
| **Lock ID** | `JobLockId.OUTBOX_DISPATCHER` (100008L — added by SBDEV-2221) |
| **Cron** | `app.cron.outbox-dispatcher=*/15 * * * * *` (every 15 s) |
| **Activation** | **Ungated — nothing switches this job off.** No per-job sysprop, and **NOT** gated by `app.cron`: plain `@Service` + method-level `@Scheduled` under the unconditional `@EnableScheduling`, so it fires on **every replica**. `app.cron.outbox-dispatcher` is the **cron expression**, not the boolean gate — see §7.7. (Corrected 2026-09-02, SBDEV-3191.) |
| **Reads** | `outbox_message` rows with `status IN ('PENDING','FAILED_RETRY')` and `next_attempt_at <= NOW()` |
| **Writes** | Per-row: flips row to `IN_FLIGHT` (claim), then to `SENT` / `FAILED_RETRY` / `FAILED_TERMINAL` depending on OMS HTTP response; deletes `SENT` rows older than 7 days at end of tick |
| **Dispatch phases** | Phase 0 (REQUIRES_NEW via `OutboxService.reclaimStaleInFlight`): recover crashed `IN_FLIGHT` rows older than 5 min back to `FAILED_RETRY`. Phase 1 (REQUIRES_NEW via `OutboxService.claimDueBatch` → `OutboxMessageRepository.findAndClaimPending`): atomically flip PENDING/FAILED_RETRY → IN_FLIGHT, release row locks. **SBDEV-2381:** the claim query now `ORDER BY next_attempt_at, id` and applies a **fail-closed cross-tick `NOT EXISTS` gate** — a row is not claimed while a lower-`id` sibling of the same aggregate is still PENDING/FAILED_RETRY/IN_FLIGHT/FAILED_TERMINAL (prevents FINISHED-without-STARTED). Phase 2 (no tx held): **SBDEV-2381:** the claimed batch is sorted in Java by `(nextAttemptAt, aggregateType, aggregateId, id)` before a sequential HTTP POST loop (no `parallelStream`); each POST goes via `HttpRestService.postWithIdempotencyKey`, each outcome committed independently via `OutboxService.mark*` (REQUIRES_NEW). |
| **Ordering (SBDEV-2381)** | Backed by index `outbox_message (aggregate_type, aggregate_id, id, status)` from migration `V2.1.14__add_outbox_aggregate_order_index.sql`. Dispatch posts events in strict per-aggregate `id` order; each POST body carries `event_version = outbox row id` for OMS-side stale-event rejection. See `architecture/wms2-oms-integration-map.md` §2.1. |
| **Per-step TX** | Each `OutboxService.mark*` call is REQUIRES_NEW — no transaction held across the OMS HTTP round-trip |
| **Metrics** | `wms2.outbox.dispatched{outcome=sent\|retry\|terminal}` (Micrometer counter); `wms2.outbox.tick_duration` (Timer wrapping the full tenant loop); `wms2.outbox.stuck_aggregate{tenant,facility}` + `wms2.outbox.stuck_aggregate.oldest_age_seconds{tenant,facility}` (per-tenant `MultiGauge`s, SBDEV-2381 Prereq #8 / plan 260614 — held-aggregate count + oldest-held age; sysprop-gated `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED`, default OFF; only the advisory-lock holder samples, cleared on lock-busy/empty-tenant; alert `max by (tenant,facility)`) |
| **Retry policy** | Exponential backoff: `nextAttemptAt = now + min(60s × 2^attempts, 1h)`. Max attempts: `app.outbox.dispatcher.max-attempts=5`. |
| **Terminal failures** | 400/404/422 or attempts ≥ max — logged at ERROR with aggregate_type + aggregate_id + idempotency_key |
| **Error resilience** | Per-tenant try-catch with `TenantContext.clear()` in `finally`; advisory lock + tick timer released in outer `finally` |
| **Landlord connection note** | The advisory lock pins a raw landlord JDBC connection for the full tick duration. With N tenants × 15 s OMS read-timeout, worst-case pin = N × 15 s. Monitor `wms2.outbox.tick_duration` to detect landlord-pool saturation. |

---

## 5. Infrastructure `@Scheduled` methods

These run on every replica unconditionally. They do **not** take advisory locks — idempotent cache refreshers and safe to overlap.

### 5.1 `TenantConfigLoader.scheduledRefresh()`

| | |
|---|---|
| **File** | `landlord/config/TenantConfigLoader.java:57-65` |
| **Schedule** | `@Scheduled(fixedDelayString = "${wms.tenant.config.refresh-interval-ms:300000}", initialDelayString = ...)` — every 5 min; `0` disables |
| **Work** | Loads all `TenantDbConfiguration` + `TenantAuthConfiguration` from landlord DB; repopulates `TenantDbConfigCache` + `TenantAuthConfigCache` |
| **Tenant context** | Never sets one; landlord-only queries via `unitName = "landlord"` |
| **Error behavior** | Exception caught at line 94 and logged; caches retain previous state; next interval retries |

Also runs **once at startup** via `@EventListener(ApplicationReadyEvent.class) @Order(0)` (line 43), blocking application readiness until the initial load completes.

### 5.2 `TenantPoolEvictor.evictIdlePools()`

| | |
|---|---|
| **File** | `landlord/config/TenantPoolEvictor.java:30-41` |
| **Schedule** | `@Scheduled(fixedDelayString = "${wms.tenant.pool.evict-interval-ms:300000}")` — every 5 min |
| **Idle threshold** | `wms.tenant.pool.idle-ms` (default `900000` — 15 min) |
| **Work** | Walks `routingDataSource.getLastAccessMap()`; for any entry where `now - lastAccess > idle-ms`, calls `routingDataSource.removeTenant(tenantKey)` → `HikariDataSource.close()` |
| **Active-connection guard** | None — `removeTenant` is called regardless; Hikari's `close()` drains gracefully |

See §4 of [wms2-tenant-routing-datasource-topology.md](./wms2-tenant-routing-datasource-topology.md) for the full pool-lifecycle view.

---

## 6. Summary Table

⚠ **Read two columns with SBDEV-3198 in mind (this table was NOT re-derived on the 2026-09-06 pass).** For the six `SchedulingConfiguration` jobs, **"Lock ID" is now only the FIRST of two keys** — the live lock is `(lockId, tenant_db_configuration.id)`, one per tenant per occurrence (§2). `100007L`/`100008L` remain genuinely one-key. And **"Default schedule" is now per-tenant** for the five grouped jobs: the value shown is what a tenant's own `*_TIMER_*` sysprops default to, not one fleet-wide firing time. Only `ReleaseExpiredPickingOrdersFromUserJob`'s hard-coded `40 * * * * *` is fleet-wide by construction.

| Job | Lock ID | Default schedule | Top-level gate | Extra gate | Per-step TX | Error scope |
|---|---|---|---|---|---|---|
| `OrderReleaseJob` | 100001L | every min (`0 * * * * *`) | `app.cron` + `NEW_CRON_JOB_ACTIVATED_KEY` | `ORDER_TIMER_ACTIVATED_KEY` | REQUIRES_NEW per order | per-order, per-tenant |
| `ReplenishOrderJob` | 100002L | every min at :20 | `app.cron` + `NEW_CRON_JOB_ACTIVATED_KEY` | `REPLENISHMENT_TIMER_ACTIVATED_KEY` + 6 sub-gates | REQUIRES_NEW per item/sub-op | per-item, per-tenant, JVM-local RUNNING |
| `StockSummaryExportJob` | 100004L | 03:00 daily | `app.cron` + `NEW_CRON_JOB_ACTIVATED_KEY` | `STOCK_SUMMARY_EXPORT_TIMER_ACTIVATED_KEY` | per-service | per-tenant, HTTP 503 capture |
| `CleanUpOldMessagesJob` | 100003L | 02:55 daily | `app.cron` + `NEW_CRON_JOB_ACTIVATED_KEY` | `CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY` (default **false**) | per-batch | per-tenant |
| `ReleaseExpiredPickingOrdersFromUserJob` | 100005L | every min at :40 (hard-coded) | `app.cron` + `NEW_CRON_JOB_ACTIVATED_KEY` | `PICK_TIME_OUT_SYSTEM_ACTIVATED_KEY` (default **false**) | per-save | per-tenant |
| `StaleClubBatchCleanupJob` (SBDEV-2164) | 100006L | sysprop-driven cron | `app.cron` + `NEW_CRON_JOB_ACTIVATED_KEY` | `STALE_CLUB_BATCH_CLEANUP_ACTIVATED_KEY` | per-batch TX inside `cleanupStaleBatches()` | per-tenant |
| `RestIdempotencyCleanupJob` (SBDEV-2222) | 100007L | `0 0 2 * * *` (app.properties) | **none — ungated, every replica** | none (no DB sysprop gate) | single DELETE per tenant | per-tenant |
| `OutboxDispatcherJob` (SBDEV-2221) | 100008L | `*/15 * * * * *` (app.properties) | **none — ungated, every replica** | none (no DB sysprop gate) | REQUIRES_NEW per phase (claim, mark*, cleanup) | per-tenant |
| `TenantConfigLoader.scheduledRefresh` | — | fixed delay 5m | unconditional | — | read-only | exception logged, cache held |
| `TenantPoolEvictor.evictIdlePools` | — | fixed delay 5m | unconditional | — | none (no DB TX) | n/a |

---

## 7. Known Landmines

### 7.7 `app.cron` and `app.cron.<job-name>` are different keys that read as the same one

**This one has already caused a documentation defect — the one corrected in §1, §4.7, §4.8 and §6 on 2026-09-02.** In `application.properties` the three keys sit on consecutive lines:

```properties
app.cron=false                                  # line 147 — BOOLEAN gate, gates SchedulingConfiguration only
app.cron.cleanup-rest-idempotency=0 0 2 * * *   # line 148 — CRON EXPRESSION, gates nothing
app.cron.outbox-dispatcher=*/15 * * * * *       # line 149 — CRON EXPRESSION, gates nothing
```

Setting `app.cron=false` does **not** stop `OutboxDispatcherJob` or `RestIdempotencyCleanupJob`. They are `@Service` beans whose `@Scheduled` methods are activated by the unconditional `@EnableScheduling` in `config/SchedulingEnablementConfig.java`. To stop them you must change their cron expression; there is no off switch. Their advisory locks (`100008L`, `100007L`) are the only thing preventing duplicate work across replicas — which is deliberate and safe, but it means "cron is disabled in this environment" is never true of these two.

### 7.8 ✅ FIXED — the schedule for ALL tenants used to come from ONE arbitrary tenant's DB (SBDEV-3191 §1 → SBDEV-3198)

**Resolved by SBDEV-3198, merged to `develop` 2026-09-03, live on dev at `develop-d4a6ab8a`.** Kept here because the measured evidence is the reason the fix exists, and because plans and reports written before 2026-09-03 describe this as open.

**What was wrong.** `SchedulingConfiguration` built **one** `CronTrigger` per job for the whole process, and each `configureX` read its `*_TIMER_HOUR`/`_MINUTE` via `syspropService.getSysvalue(...)` under a single tenant's `TenantContext`. `los_sysprop` lives in the **tenant** DB, so whichever tenant won an arbitrary `ConcurrentHashMap` iteration set the schedule for every tenant in the process.

Measured 2026-09-02 on the four active UAT tenants (one deployment) — the evidence that made the case:

| UAT tenant | `STOCK_SUMMARY_EXPORT_TIMER_HOUR` | `System Time Zone` |
|---|---|---|
| hydra/nywh | 3 | America/New_York |
| shipitez/nywh | 3 | America/New_York |
| shipitez/c1wh | 18 | America/Los_Angeles |
| wineco/wsl | 17 | America/Los_Angeles |

A 15-hour swing in when the nightly full-inventory export to OMS fired. Only `STOCK_SUMMARY_EXPORT_*` diverged — all four agreed on `CLEAN_UP_OLD_MESSAGES_TIMER_HOUR`=2, `STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR`=3 and `ORDER_TIMER_*`/`REPLENISHMENT_TIMER_*`=`*` — but that was a coincidence of configuration, not a property of the code.

**Latent on dev and prd, live on UAT:** `dev_landlord` had 1 active tenant of 4, `wms2_landlord` (prd) exactly 1 (`hydra/nywh`), `landlord` (uat) 4. With one active tenant the arbitrary winner is the only tenant, so the defect would have armed itself on prd the moment a second tenant was onboarded.

**How it was fixed — Option D′, not the obvious fix.** Registering one `CronTrigger` per tenant would **not** have worked, for two independent reasons: (a) every job already iterates all active tenants at fire time from `tenantDbConfigurationRepository.findByActiveTrue()`, so N per-tenant triggers produce N² tenant-executions; and (b) `JobLockId` held one fixed constant per **job** pinned on the shared `landlordDataSource`, so N simultaneous per-tenant triggers contend on one lock id and N−1 skip silently at DEBUG.

D′ groups tenants by **firing specification** instead: one trigger per distinct `TriggerSpec`, membership re-derived at fire time, and a two-key advisory lock on `(jobId, tenant_db_configuration.id)`. See §4's current shape and §4.0. Five of the six jobs are grouped; `releaseExpiredPickingOrdersFromUser` has no timer sysprop to group on and stays a single trigger.

⚠ **Two traps this fix walked past, both still relevant to anyone extending it.** The lock key must contain **no group-membership-derived component** — a membership hash or a group ordinal are both unsound, and AC12 pins their absence (§2 has the reasoning). And zone-invariant crons must collapse to one trigger, or a per-minute cron fans out per distinct tenant zone (§4.0).

**Verifying it on a real deployment** still needs a boot log, and dev cannot show it: with one active tenant, per-tenant and fleet-wide schedules are indistinguishable. On UAT's four tenants, each `Configured <job>` line names its schedule-source tenant and resolved zone (SBDEV-3191 Slice A's provenance logging, written for exactly this read). **That check has not yet been done** — SBDEV-3198 AC1/AC2 remain open on environment verification, not on code.

### 7.9 ✅ FIXED — cron firing zone used to be hard-coded to America/Los_Angeles (SBDEV-3191 §2 → SBDEV-3198)

**Resolved by SBDEV-3198 together with §7.8** — the two shared a root cause (one fleet-wide trigger) and could not be fixed separately.

**What was wrong.** `SchedulingConfiguration.CRON_SCHEDULE_ZONE = TimeZone.getTimeZone("America/Los_Angeles")` applied to every `CronTrigger`. This was **live on production**, unlike §7.8, and with only one tenant: Hydra's `System Time Zone` is `America/New_York` and its export hour is 3, so the nightly export fired at 03:00 LA = **06:00 New York**, inside the NY morning shift.

**What the fix needed that the original analysis missed.** An early revision of the SBDEV-3198 design claimed *"no new zone plumbing is needed"* because `TimezoneService.getWarehouseZoneId()` already resolves a tenant's zone from the `"System Time Zone"` sysprop. **That was wrong** and is worth remembering: **both `getWarehouseZoneId` overloads throw without a `TenantContext`**, and there was no `(tenantName, facilityCode)` form — so resolving N tenants' zones on the registration thread required either a new overload or a per-tenant set/clear dance around each read. Each grouped `configureXGroups` now does that per-tenant resolution and carries the result in `TenantSchedule.resolvedZone`.

A tenant whose zone cannot be resolved **falls back to UTC with a WARN** and must be **named in the registration provenance line** rather than being silently pooled with genuine UTC tenants (AC2′).

⚠️ **`CRON_SCHEDULE_ZONE` was NOT deleted — it is still live at `SchedulingConfiguration:78` and still used.** The one-arg `register(...)` overload (`:1422`) builds `new TriggerSpec(cronExpression, CRON_SCHEDULE_ZONE.getID())`, and `releaseExpiredPickingOrdersFromUser` — the one non-grouped job — still registers through it. This is **harmless**, because that job's cron `"40 * * * * *"` fires at identical instants in every zone, and the code says so at `:120` and `:310`. But note the consequence for anyone reading a registered spec: because the one-arg path bypasses `TriggerSpec.of(...)`, that spec's `zoneId` is the literal string `"America/Los_Angeles"`, **not** the `ZONE_INVARIANT` sentinel — `TriggerSpec`'s own javadoc `:19-26` states this. So "zone-invariant cron" and "spec marked zone-invariant" are not the same property, and only the five grouped jobs get the sentinel.

### 7.10 The boot probe is not duration-bounded — but it does terminate (SBDEV-3204)

⚠ **This section asserted the opposite until 2026-09-02 and was wrong.** It claimed a wedged tenant DB "hangs the boot thread indefinitely, the retry counter never advances, and even the ERROR that SBDEV-3191 Slice A added never fires." That was inferred from pgjdbc's documented defaults, never measured, and it is false for every failure shape that can actually be reproduced.

**Measured, pgjdbc 42.7.8, time to failure with _no_ properties set:**

| failure shape | no properties | `connectTimeout=3` | `loginTimeout=2` | `socketTimeout=2` |
| ---| ---| ---| ---| --- |
| SYN dropped (unroutable address) | **10.23s** | 3.02s | 2.00s | n/a |
| TCP accepted, then no bytes ever sent | **5.19s** | 5.03s (**no effect**) | 2.00s | 2.01s |

The 10s figure is pgjdbc's documented `connectTimeout` default. The ~5s figure has **no identified mechanism** — `connectTimeout` provably does not govern it.

There are **two** connects per tenant per attempt (the raw probe, then `new HikariDataSource`), so the per-tenant cost is the pair — also measured:

| failure shape | connect 1 (raw probe) | connect 2 (`new HikariDataSource`) | pair |
| ---| ---| ---| --- |
| SYN dropped | 10.23s | 11.10s | **21.3s** |
| accept-then-silence | 5.29s | 6.08s | **11.4s** |

Against UAT's four active tenants all down, Slice A's exhaustion ERROR therefore arrives in **roughly 45–85 minutes**, not never. (The pre-correction estimate of "~40s per tenant / ~2.7h" over-stated it by assuming connect 2 consumes its full `connectionTimeoutMs` of 30000; measured, it fails as soon as the driver does.) 45 minutes is still far too long to leave an operator unsignalled, which is why Slice A's attempt-1 WARN matters — but it is not the only signal that survives.

**What IS genuinely unbounded**, and why SBDEV-3204 stays open in backlog: a **post-handshake read**. `PGProperty` defaults are `connectTimeout=10`, `socketTimeout=0`, `loginTimeout=0`, so a tenant DB that completes TCP, completes authentication and *then* stalls mid-query has no bound — and `resolveWarehouseTz` runs a `SELECT` after connecting. **Not reproduced**: it needs a server that speaks the PG wire protocol and then stalls, which a bare `ServerSocket` cannot do. Plausible and unmeasured, not established.

**⚠ If bounding it: do NOT set a pool-wide `socketTimeout`.** pgjdbc's `socketTimeout` is a per-read timeout applied to every statement on the connection, so pool-wide it is a de-facto global query timeout — `StockSummaryExportJob` streams a cursor across every `itemdata` row and a modest value would kill it mid-stream. Bound *establishment* on the pool, read timeouts only on the one-shot probe. Also note the fix needs **no** landlord data change: an earlier claim that it required editing six `db_url` rows across three environments was wrong — it is a `Properties` argument in code, at the single `DriverManager.getConnection` call site in all of `src/main`.

1. **Advisory locks break under PgBouncer transaction pooling.** ⚠ **Re-derived 2026-09-06 — the premise changed and it matters here.** There are **six** gated business jobs, not five, and since SBDEV-3198 the lock is taken and released **inside the per-tenant loop**, not held for the whole run: scope is now one tenant's slice, not the occurrence. It is still a **session-level** lock, so the PgBouncer hazard stands — but the blast radius of losing it is now per-tenant, and the "hold for entire run" semantics named in the mitigation options below no longer describe the code. Under PgBouncer `pool_mode=transaction`, the lock is released at transaction boundary — which, for a job that spans many transactions, means every replica's retry window sees a free lock and can enter. Either switch to `pool_mode=session` for the landlord DB, rewrite to `pg_try_advisory_xact_lock` with the lock taken at the start of each iteration (incompatible with "hold for entire run" semantics), or move the mutex to Redis. See `PgBouncer_Connection_Pool_Strategy_2026-04-05` for the full rollout.

2. **Scheduler thread pool is size 10, shared with infrastructure jobs.** A single hung tenant in `OrderReleaseJob` or `ReplenishOrderJob` ties up a scheduler thread. If multiple long runs pile up, `TenantConfigLoader` and `TenantPoolEvictor` fail to fire on schedule — which in turn starves new-tenant discovery and stops pool eviction. No alerting on this today.

3. **Two jobs ignore sysprop cron settings.** `ReleaseExpiredPickingOrdersFromUserJob` has `40 * * * * *` hard-coded (`SchedulingConfiguration:1145` at `d4a6ab8a`; this cite read `line 223`). `StockSummaryExportJob`'s seconds field is hard-coded `0`. Changing cadence means a code change + deploy, not a sysprop update.

4. **Per-job activation defaults are inconsistent.** `ORDER_TIMER_ACTIVATED_KEY` and `REPLENISHMENT_TIMER_ACTIVATED_KEY` default to `true`; `CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY` and `PICK_TIME_OUT_SYSTEM_ACTIVATED_KEY` default to `false`. Easy to miss when enabling `app.cron=true` in a new environment.

5. **Tenant context is manual everywhere in jobs.** Each business job sets/clears `TenantContext` in a per-tenant try/finally. A refactor that accidentally drops the `finally { TenantContext.clear(); }` would leak context across iterations — the next tenant's work would silently run against the previous tenant's DB.

6. **~~No Micrometer timers on any job.~~** ✅ **Resolved by SBDEV-2238-4.5 (2026-05-18).** **Five of the six** business cron jobs — `OrderReleaseJob`, `ReplenishOrderJob`, `StockSummaryExportJob`, `CleanUpOldMessagesJob`, `ReleaseExpiredPickingOrdersFromUserJob` — emit Micrometer metrics (⚠ note this "five" is **not** §1's six: `StaleClubBatchCleanupJob` is the sixth gated job and still has no `JobMetrics` field or reference at all, re-confirmed 2026-09-06 — which is the parity gap named at the end of this item) via the new `JobMetrics` helper class (`schedulejob/JobMetrics.java`). Metrics per job: `wms2.cron.<job>.duration` (full-run Timer), `wms2.cron.<job>.tenant_duration{tenant}` (per-tenant Timer), `wms2.cron.<job>.success{tenant}`, `wms2.cron.<job>.failure{tenant,reason}`, `wms2.cron.<job>.skipped_lock_busy`, `wms2.cron.<job>.skipped_not_activated{tenant}`, `wms2.cron.<job>.rows_processed{tenant}`, `wms2.cron.<job>.last_run_epoch_seconds` and `last_success_epoch_seconds` gauges. ⚠ **The per-job set is no longer uniform.** SBDEV-2961 (2026-08-14, unmerged) adds two `OrderReleaseJob`-only counters: `wms2.cron.order_release.orders_skipped_no_section{tenant}` (incremented **every tick** for every order whose client has no Section — standing volume, for a dashboard) and `wms2.cron.order_release.orders_marked_no_section{tenant}` (**transitions only** — this is the one to alert on). The split is deliberate: a single per-tick counter would make an `increase(...) > 0` alert fire continuously from the moment the first mis-configured client exists until the data is backfilled (SBDEV-2963), and an always-red alert gets muted. `micrometer-registry-prometheus` added to `pom.xml`; `prometheus` added to `management.endpoints.web.exposure.include`. `OutboxDispatcherJob` already had its own Micrometer counters from SBDEV-2221. `StaleClubBatchCleanupJob` and `RestIdempotencyCleanupJob` are a **parity gap** — not instrumented in this ticket.

7. **~~`CleanUpOldMessagesJob` batched delete loop is unbounded.~~** ✅ **Resolved by SBDEV-2220 (2026-05-10).** Batch size is now sysprop-driven (`CLEAN_UP_OLD_MESSAGES_BATCH_SIZE`, default 1000, clamped [1, 100000]), each batch runs in its own REQUIRES_NEW tx, and an optional inter-batch sleep is available via `CLEAN_UP_OLD_MESSAGES_BATCH_SLEEP_MS`. The loop terminates when a batch returns fewer than batchSize rows.

8. **`ReplenishOrderJob.RUNNING` guard is JVM-local.** It protects against two timer fires on the same replica; it does **not** protect across replicas (that's the advisory lock's job). If the lock breaks (landmine #1), the AtomicBoolean is not a safety net.

9. **No retry beyond per-item continue.** When a tenant fails, it's logged and skipped. The next scheduled tick retries the whole tenant from scratch — fine for idempotent sub-ops, but a long-lived stuck state (e.g. a tenant that always throws `OptimisticLockException` on the same row) will spin silently forever.

10. **Infrastructure jobs share the same scheduler pool.** If every business cron job is live and one hogs the pool, `TenantConfigLoader.scheduledRefresh` will delay too, and new tenants will take longer than 5 min to become routable.

---

## 8. Operational Runbook Hooks

Not a runbook, but cross-referenced:

| If you see… | Start at |
|---|---|
| "Job X ran twice, wrote double state transitions" | §2 (lock ID present?), §7 item 1 (PgBouncer?) |
| "Cron job on replica A runs fine, replica B never fires" | §3.3 (did the 60 s startup gate timeout?), §7 item 10 (pool starved?) |
| "ReplenishOrderJob tenant failures in logs" | §4.2 error resilience, then `260424-connection-pool-exhaustion-fix-plan.md` and the replenish debug plans |
| "New tenant not appearing after config row inserted" | §5.1 (5 min refresh) or hit `/v3/tenant/health` for the tenant |
| "Cron should fire every minute but fires erratically" | §3.2 pool size 10 — is another job blocking threads? |
| "OMS isn't getting stock summary at 3am" | §4.3 — check `WEBSERVICE_STOCK_COUNT_URL_KEY` + `STOCK_SUMMARY_EXPORT_TIMER_ACTIVATED_KEY` + `message` table for 503s |
| "Picking orders staying locked to operator after crash" | §4.5 — but only activates if `PICK_TIME_OUT_SYSTEM_ACTIVATED_KEY=true` (default false) |

---

## 9. How to use this doc

| Task | Start at |
|---|---|
| Add a new cron job | §2 (reserve next lock ID — `100001L`–`100008L` are **all taken**, so the next free is `100009L`; and decide the **lock form** deliberately, see §2's per-job lock-shape table), §4 (copy the skeleton), §3.1 (wire in `SchedulingConfiguration`), §7 items 1/4/5 |
| Enable cron in a new environment | §3.4 (`app.cron=true` + per-job activation sysprops) |
| Plan PgBouncer migration | §7 item 1 in full + `260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md` |
| Tune a job's cadence | §4.x (find the sysprop key in the relevant job's table), then update landlord sysprop — except for the two hard-coded in §7 item 3 |
| Diagnose "cron silently not running" | §3.3 startup gate, §3.4 gates, §6 summary table |

---

## 10. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-09-06 (3rd pass) | **Second independent audit, of the corrections themselves — four fixes were incomplete and two of those were defects the correction pass CREATED.** (1) `wms2-tenant-routing-datasource-topology.md` still asserted *"All eight jobs follow the canonical advisory-lock-first / per-tenant-iteration shape"* **twelve lines below** the correction that replaced the same claim — and "advisory-lock-**first**" was wrong in a second way, since for the five grouped jobs the lock is taken *inside* the tenant loop and *after* the spec check (`StaleClubBatchCleanupJob:141`→`:158-159`→`:190`). (2) Correcting §4.2's heading from "Six" to "Nine" exposed what the miscount had hidden: the list named only **8 of the 9** calls — `generateReplenishmentForItemDataWithFixedAssignmentWithOrders` was absent entirely — and the paragraph below still said "each of the 6 sub-ops". (3) **§3.4's heading said sysprops live in the LANDLORD DB. They live in the TENANT DB** (`Sysprop` is `@Table("los_sysprop")`; `SyspropService` is `@Transactional("tenantTransactionManager")` with a `TenantContext`-keyed cache) — a pre-existing error that **contradicted §7.8 of this same doc**, where per-tenant sysprops are the entire premise of the defect. The topology doc repeated it and added two more: `line 24`→`:30`, and "cron expressions come from `SyspropService`" is false for exactly the three jobs its own new exception list names. (4) §3.3 step 3's `lines 135, 137, 143`→`:566`/`:569`/`:584`. **Rationale corrections:** the dual-lock "why two jobs and not six" paragraph was sourced for three of four siblings but **`StaleClubBatchCleanupJob` was an inference** — the word "dual" does not appear in that file; its recorded reason is stronger and different, namely that `STALE_CLUB_BATCH_CLEANUP_ACTIVATED` was measured `false` on every UAT tenant and prd hydra 2026-09-02, so the job is **inert everywhere** ("inert" means nothing to back-fill; "predates the mechanism" would have implied an oversight to go and fix). Added: the dual lock is declared a **ONE-RELEASE transitional shape, deleted next release** (`StockSummaryExportJob:57-58`) — §2 had documented it as permanent current state; PR #288's H-1 **re-scoped** an already-decided mitigation rather than adding it; and `runForCurrentTenant` has **two** non-scheduler callers, the second being `StockCountRestController:111` on `/rest/**`, which was absent from the whole vault. Four locator-less Error-resilience rows given a greppable symbol handle (`catch (Exception e)` in `runFor`) instead of a bare parenthetical, and the picking-workflow diagram node named `CustomerorderService.setPickingDate()` (`:257`, verified) instead of left blank. | 2 self-inflicted defects + 2 incomplete fixes closed; 1 pre-existing landlord/tenant error corrected in 2 docs; 3 rationale claims re-sourced or retracted | Second independent review lane (opus), same method — every cell of all four new tables re-derived (16 lock-shape call sites, 16 entry-point cells, 3 webhook rows, 9 declared + 9 inherited `@PreAuthorize` lines): **no arithmetic or line-number error found in any of them.** `setPickingDate:257` and the tenant-transaction-manager finding independently re-verified here before acceptance. **STILL NOT verified by any pass — needs a DB or a deploy:** §7.8's UAT sysprop table and zone column, the landlord active-tenant counts, §7.10's pgjdbc timings, and now also `StaleClubBatchCleanupJob:24-28`'s "inert on every UAT tenant and prd hydra" claim, which this doc now leans on and which is dated 2026-09-02 rather than re-measured. No tests, no `mvn`, no PIT were run in any pass. |
| 2026-09-06 (2nd pass) | **Independent adversarial audit of the same-day rewrite above — five confirmed-wrong claims in MY OWN edits, and 18 adjacent claims the SBDEV-3198 change had falsified and left standing.** The pattern repeated the one this ticket already recorded: **every quantitative claim survived re-derivation; every completeness claim broke.** Corrected in §2 — the one-key form is used by **four** lock ids, not `100007L`/`100008L` "only", because `CleanUpOldMessagesJob` and `StockSummaryExportJob` hold a **dual lock** (one-key per tenant wrapping the two-key, a deliberate mixed-version guard from PR #288's H-1, cloned in #291) which had **zero** coverage anywhere; the knock-on §4 claim that co-firing tenants "no longer serialise" was false for those two. In §4 — "three entry points per job" holds for **4 of 6** (`ReleaseExpiredPickingOrdersFromUserJob` has no `deriveSpecForCurrentTenant` and a **no-arg** `runFor()`; `StaleClubBatchCleanupJob` has no `runForCurrentTenant`, so there are **5** declarations, not 6). In §2 — my retraction of the "two independent Portainer webhooks" claim **over-generalised in the reassuring direction**: it is FALSE for prd but **true verbatim for dev and UAT** (`docker-image-develop.yml:45-46`, `docker-image-uat.yml:133-134` each fire two live sequential curls), i.e. the mixed-version window is measured-present exactly where the dual-lock path is exercised. In §7.9 — **`CRON_SCHEDULE_ZONE` was not deleted**, it is live at `:78` and still used by the one non-grouped job via the one-arg `register` at `:1422`, which bypasses `TriggerSpec.of` so that spec's `zoneId` is the literal zone, not the `ZONE_INVARIANT` sentinel. Plus §4.0's zone-invariance restated in field names rather than indices, and `skippedLockBusy` noted as per-tenant, not per-group. **Adjacent drift fixed:** `isTenantDatabaseInitialized()` in §3.3 **no longer exists** (replaced by `awaitReachableTenantAndConfigure:394`/`probeForReachableTenant:533`, with the 60/1000ms figures now `@Value`-driven); §3.3's "all five business cron jobs" → six; §7 item 1's "All five … hold the lock for their entire run" → six, and the lock is now taken **inside** the per-tenant loop, which is load-bearing for the PgBouncer hazard §1 points here for; §7 item 6's "five" flagged as a **different** five (`StaleClubBatchCleanupJob` still has no `JobMetrics`); §7.7's `app.cron` cite stale a **third** time (`:139`→`:147/:148/:149`); §7 item 3's `line 223`→`:1145`; §9's next-free lock id `100006L`→`100009L`; §3.2's bean and pool-size cites; and **six §4 "Error resilience" line cites that all pointed at javadoc, constructors or class declarations — replaced with symbol names rather than re-derived numbers**, since these have now gone stale three times. The duplicate "Last verified" line in the header (which contradicted the frontmatter by four months) was removed rather than re-synced. | 5 confirmed-wrong + 3 overstated claims of mine corrected; 18 adjacent claims fixed; §2 and §4 gained the per-job lock-shape and entry-point tables that make the non-uniformity visible | Independent review lane (opus), deriving every claim via `git show`/`git grep` against `origin/develop` @ `d4a6ab8a`, with positive controls on all zero-results. **NOT checked by that lane:** anything needing a DB or the network — so §7.8's UAT sysprop table, the landlord active-tenant counts, the `/api/public/version` reading and all of §7.10's pgjdbc timings remain on trust; also §6's table body and §4's read/write and per-step-TX cells. No tests were run. |
| 2026-09-06 | **SBDEV-3198 shipped — §7.8 and §7.9 rewritten from OPEN to FIXED.** Both had described live production defects that were merged-and-fixed four days earlier; §7.9 still read "Blocked behind §7.8's Slice B" and §7.8's trap paragraph still prescribed "per-tenant job entry points **and** per-tenant lock ids" as the correct fix — which is *not* what shipped (D′ groups by firing specification, and AC12 forbids any group-derived lock component). Also corrected: §2's "SBDEV-3198 must add a two-key method" retensed to done, with the four-method `AdvisoryLockService` surface tabulated and the **wrong** OMS-double-send justification for leaving `100007L`/`100008L` on one-key replaced (`findAndClaimPending` already uses `FOR UPDATE SKIP LOCKED`); §2's "two independent Portainer webhooks" claim marked **disproved for prd** (one webhook, commented out — so the mixed-version hazard is probably absent but unverified, AC5); §4's shared skeleton replaced (`doCalculation(Boolean)` is **gone from `src/main`** — zero declarations, zero call sites) with the three-entry-point D′ shape; new §4.0 documenting `TriggerSpec`/`TenantSchedule`, which had **zero** coverage anywhere in `sbdocs/`; all six §4 **Wired** rows renamed to `configureXGroups()` with re-derived lines; §4.2's `RUNNING` guard reclassified from "defense-in-depth" to **resource throttle** per the PR that deliberately kept it; §1 fact 2 given the six-jobs-but-five-grouped-plus-one trigger-count caveat; §6 header caveat on the Lock ID and Default schedule columns. | §7.8/§7.9 rewritten; §2, §4 preamble, §4.0 (new), six §4 Wired rows, §4.2, §1, §6 corrected | `git grep`/`git show` against `origin/develop` @ `d4a6ab8a` for every symbol claim, incl. a negative check that `doCalculation` has no declaration or call site; PR bodies #278–#304 for the decision provenance; `GET /api/public/version` for the deployed build. **NOT re-verified:** per-job transaction boundaries, §4 read/write inventories, the §6 table body, PgBouncer items, and AC1/AC2 on a real UAT boot log — that last one is still open on the ticket |
| 2026-04-19 | All `@Scheduled` annotations under `src/main/java`, `AdvisoryLockService.JobLockId` constants, `SchedulingConfiguration` wiring, per-job activation/cron sysprop keys, error-handling shape, TX annotations on each inner service method, `TaskScheduler` bean definition, `SchedulingEnablementConfig` | All counts and file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-08 | `service/job/*` directory contents (CleanUpOldMessageJobService, ReleaseOrderJobService, ReplenishOrderJobService, **StaleClubBatchCleanupJobService** — added by SBDEV-2164). `schedulejob/` contains 6 business jobs + 1 SchedulingConfiguration. `JobLockId` enum has 6 entries (added `STALE_CLUB_BATCH_CLEANUP = 100006L`). §1 overview, §2 lock-id table, §6 summary, §4.6 added. Group C resolutions (commits in `OrderReleaseJobService` / `ReplenishOrderJobService` re: optimistic-lock catches) confirmed: 9 sites of `OptimisticLockingFailureException` / `OptimisticLockException` catches across these two services per current source tree. | All counts and file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-12 | SBDEV-2222: `RestIdempotencyCleanupJob.java` added to `schedulejob/`; `JobLockId.CLEANUP_REST_IDEMPOTENCY = 100007L` added to `AdvisoryLockService`; cron driven by `app.cron.cleanup-rest-idempotency=0 0 2 * * *` (no DB sysprop gate). §2 lock-id table, §4.7 detail block, §6 summary updated. `schedulejob/` now contains 7 business jobs. | §2 +1 row, §4.7 added, §6 +1 row confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-17 | SBDEV-2221: `OutboxDispatcherJob.java` added to `schedulejob/`; `OutboxDispatchService.java` added to `service/job/`; `JobLockId.OUTBOX_DISPATCHER = 100008L` added to `AdvisoryLockService`; cron every 15 s (`app.cron.outbox-dispatcher=*/15 * * * * *`, no DB sysprop gate). §1 overview updated (7 business jobs), §2 lock-id table +1 row, §4.8 detail block added, §6 summary +1 row. `schedulejob/` now contains 8 business jobs. | §2 +1 row, §4.8 added, §6 +1 row confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-18 | SBDEV-2238-4.5: `JobMetrics.java` helper added to `schedulejob/`; all 5 existing business cron jobs instrumented (`OrderReleaseJob`, `ReplenishOrderJob`, `StockSummaryExportJob`, `CleanUpOldMessagesJob`, `ReleaseExpiredPickingOrdersFromUserJob`). `micrometer-registry-prometheus` added to `pom.xml`; `prometheus` added to `management.endpoints.web.exposure.include`. §7.6 landmine resolved (was "No Micrometer timers on any job"). Parity gap: `StaleClubBatchCleanupJob` (100006L) and `RestIdempotencyCleanupJob` (100007L) not yet instrumented. | §7.6 resolved, verification log updated | Code read (grep-based) |
| 2026-08-14 | SBDEV-2961 (**unmerged** branch `feature/SBDEV-2961-order-release-silent-section-exclusion`): `JobMetrics` gains `tenantOrdersSkippedNoSection` / `tenantOrdersMarkedNoSection`, emitting the first **job-specific** counters — §7.6's "metrics per job" list is no longer a uniform set and now carries a caveat. `OrderReleaseJob` also gains a guard that marks section-less orders `CLIENT_HAS_NO_SECTION(45)` and skips them, and its pre-round gate now excludes 45. No new `@Scheduled` method, no advisory-lock id consumed, no sysprop added. | §7.6 metric list annotated + this row; the job inventory, lock-id table and cron expressions were NOT re-verified, so `last_verified` stays at 2026-06-01 | Code read of the branch diff |
| 2026-06-01 | SBDEV-2381: `OutboxDispatchService` / `OutboxMessageRepository.findAndClaimPending` — claim query gained `ORDER BY next_attempt_at, id` + fail-closed cross-tick `NOT EXISTS` ordering gate; `dispatchBatch` sorts the claimed batch by `(nextAttemptAt, aggregateType, aggregateId, id)` before a sequential POST loop; each POST body carries `event_version = outbox id`. New index migration `V2.1.14`. Advisory lock 100008L and `*/15 * * * * *` cadence unchanged. §4.8 Dispatch-phases row + new Ordering row added. | §4.8 updated; ordering confirmed against `OutboxMessageRepository.findAndClaimPending` + `OutboxDispatchService.dispatchBatch/dispatchOne` (PR #35, commits 567fba3 + 41ad7d3) | Code read (grep-based) |

| 2026-09-02 | SBDEV-3204: **corrected §7.10, which asserted the opposite of the truth.** It claimed the boot probe hangs indefinitely against a wedged tenant DB and that Slice A's ERROR "never fires". Measured on pgjdbc 42.7.8: both reproducible wedge shapes terminate with no properties set — 10.2s for a dropped SYN (the documented `connectTimeout` default) and 5.2s for accept-then-silence (mechanism unidentified; `connectTimeout` does not govern it). Measured as a PAIR of connects per tenant (raw probe + `new HikariDataSource`): 21.3s SYN-drop, 11.4s accept-then-silence, so the exhaustion ERROR arrives in ~45–85min with four tenants down, not never. The genuinely unbounded path is narrowed to a post-handshake read (`socketTimeout=0`), which is documentation-derived and **not reproduced**. Added the warning against a pool-wide `socketTimeout` (it is a per-read timeout = a global query timeout, and `StockSummaryExportJob` streams a cursor over every `itemdata` row). Same correction applied to `SchedulingConfiguration`'s javadoc. | §7.10 rewritten | Direct measurement against a local stalling `ServerSocket` and an RFC5737 address, plus `PGProperty` defaults read from the driver |
| 2026-09-02 | SBDEV-3191: **corrected a wrong gating claim.** §1 said "nine recurring workloads: seven business cron jobs gated by `app.cron=true`"; the real figure is **ten** in three gating classes, and `OutboxDispatcherJob` + `RestIdempotencyCleanupJob` are **not** `app.cron`-gated at all (plain `@Service` + `@Scheduled` under unconditional `@EnableScheduling`), so they fire on every replica. §4.7, §4.8 and the two §6 rows said "controlled by `app.cron` only" and were wrong the same way. `app.cron` line reference drifted `:111` → `:139`. Added §7.7 (the `app.cron` vs `app.cron.<job>` naming trap that caused this defect), §7.8 (one arbitrary tenant supplies every tenant's schedule, with measured UAT divergence and the reason the obvious fix is a trap), §7.9 (firing zone hard-coded to LA, live on prd), §7.10 (boot probe not duration-bounded). Slice A of SBDEV-3191 landed the per-tenant boot probe + provenance logging; §1/§2 remain open as Slice B. | §1 rewritten, §4.7/§4.8/§6 corrected, §7.7–§7.10 added; job inventory and lock-id table re-derived | `git grep` over `src/main` at `daae54a6` with a positive control, plus live psql against dev/uat/prd landlord + tenant DBs |

**Re-verify every 60 days.** Next due: **2026-11-01** — or sooner if `app.cron` is enabled in production, new jobs added, or PgBouncer migration lands (items in §7 will change).
