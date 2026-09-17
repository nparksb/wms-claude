---
title: "SBDEV-3321 lane B — F5: the pending-reversal reconciliation job"
type: evidence
status: analysis complete
ticket: SBDEV-3321
version: v2
repo: v2/wms2-api
code_base: "origin/develop @ e113467b (fetched 2026-09-16); schedulejob/ and the cancellation-log surface are byte-identical to the local checkout's HEAD 4bef7e77 — `git diff --stat HEAD origin/develop` touches only PickingorderRepository, CustomerorderService, PickingorderBusinessService, WmsConstants, MobilePickingService and three test classes"
deployed_prd_build: "0.0.26 (GET https://wms-api.sbo.li/api/public/version, 2026-09-16, drift=false)"
created: 2026-09-16
owner: Nam Park
---

# F5 — reconciliation job for stale pending cancellation reversals

**The subject, verbatim.** `sbdocs/4-Archieves/wms2/plan/SBDEV-1921-order-cancellation-reversal-workflow.md:1130`:

> `- F5: Consider a daily reconciliation job that emails ops if pending reversals are >24 h old.`

Its sibling, also never built, is one line above:

> `- F4: Add Grafana dashboard panel for pending reversal count per tenant.`

Both matter to §4 below: **F5 as written is not implementable in this codebase** (there is no mail
capability at all) and **F4's channel is unwatched** (nothing scrapes Prometheus; the endpoint 401s).
Read §4 before picking a mechanism.

---

## 1. The canonical scheduled-job pattern

Derived by reading three jobs end to end on `origin/develop`: `RestIdempotencyCleanupJob` (150 lines),
`OutboxDispatcherJob` (169), `StaleClubBatchCleanupJob` (245), plus `SchedulingConfiguration` (1751,
read at the registration and `register(...)` sites), `AdvisoryLockService`, `JobMetrics`,
`JobMetricsConfiguration`, `TriggerSpec`, `TenantSchedule`, `SchedulingEnablementConfig`.

### 1.1 There are TWO patterns, not one. Pick deliberately.

| | **Pattern A — `@Scheduled` + global cron** | **Pattern D′ — registered `CronTrigger`** |
|---|---|---|
| Members | `OutboxDispatcherJob` (2 lanes), `RestIdempotencyCleanupJob` | the six `SchedulingConfiguration` jobs |
| Activated by | the **unconditional** `@EnableScheduling` in `config/SchedulingEnablementConfig.java` — *"Enables the Spring scheduling infrastructure on ALL replicas (unconditionally)."* | `@ConditionalOnProperty(name = "app.cron", havingValue = "true", matchIfMissing = false)` on `SchedulingConfiguration:30` |
| Runs on | **every replica** | only the replica with `app.cron=true` |
| Schedule | one fleet-wide Spring cron property | per-tenant, from that tenant's `*_TIMER_HOUR`/`_MINUTE` sysprops, in that tenant's resolved zone |
| Advisory lock | **one-key** `tryLock(long)` — job-wide | **two-key** `tryLock(long, long)` — `(jobId, tenant_db_configuration.id)` |
| Tenant gates | **none** | `NEW_CRON_JOB_ACTIVATED` **AND** its own `*_ACTIVATED` sysprop |
| `JobMetrics` | no (`OutboxDispatcherJob` hand-rolls its own `MeterRegistry` calls) | 5 of 6 have a `JobMetrics` bean; `StaleClubBatchCleanupJob` has none |

⚠ **`app.cron` and `app.cron.<something>` are different keys that read as the same one.**
`application.properties:162` is `app.cron=false` (a boolean gate); `:163`, `:176` and `:179` are
`app.cron.cleanup-rest-idempotency`, `app.cron.outbox-dispatcher` and `app.cron.outbox-dispatcher-club`
— **cron expressions that gate nothing**. Setting `app.cron=false` does not stop a Pattern A job.

### 1.2 Next free `AdvisoryLockService.JobLockId` constant: **`100010L`**

Current high-water mark is **`100009L`** — `OUTBOX_DISPATCHER_CLUB`, the last field of the nested
`public static final class JobLockId` (`service/AdvisoryLockService.java`, block at `:248-266`):

```java
public static final long OUTBOX_DISPATCHER = 100008L; // SBDEV-2221
// Second outbox consumer, for the CLUB lane only. ...
public static final long OUTBOX_DISPATCHER_CLUB = 100009L;

private JobLockId() {}
```

**How that was derived, and its blind spots.** `JobLockId` is a `final` class with a private
constructor, so reading its whole body (19 lines) enumerates every constant *by construction* — this
is not a grep sample. The one thing a body-read cannot see is a lock id passed as a **raw literal**
somewhere else, so I also ran `grep -rn '1000[0-9][0-9]' src/main --include=*.java` excluding
`AdvisoryLockService.java`: 18 hits, all of them either javadoc naming an existing id
(`{@code (100003, tenantId)}` etc.) or the unrelated `PRIORITY_IMMEDIATE = 100000` and its uses in two
repository native queries. Remaining blind spot: an id computed at runtime rather than written
literally — none exists today, but a grep cannot prove that.

⚠ **Never change an id *or its lock form*.** The one-key and two-key advisory-lock spaces are
**disjoint** in PostgreSQL: `pg_try_advisory_lock(100008)` does not exclude
`pg_try_advisory_lock(100008, 2)`. `AdvisoryLockService`'s class javadoc states this and
`AdvisoryLockServicePerTenantLockUnitTest` pins that `100007L`/`100008L` stay one-key.

### 1.3 Skeleton — Pattern A (recommended for F5; see §4.6)

This is `RestIdempotencyCleanupJob` with the names changed. Every construct below is copied from it,
including the two-level catch, which is load-bearing.

```java
@Service
public class PendingReversalReconciliationJob {

    private static final Logger LOG = LoggerFactory.getLogger(PendingReversalReconciliationJob.class);

    private final AdvisoryLockService advisoryLockService;
    private final TenantDbConfigurationRepository tenantDbConfigurationRepository;
    private final PendingReversalAlertService alertService;   // the per-tenant unit of work

    // constructor injection only — no field @Autowired anywhere in schedulejob/

    @Scheduled(cron = "${app.cron.pending-reversal-reconcile:0 30 2 * * *}")
    public void reconcile() {
        if (!advisoryLockService.tryLock(AdvisoryLockService.JobLockId.PENDING_REVERSAL_RECONCILE)) {
            LOG.debug("pendingReversalReconcile already running on another replica, skipping");
            return;                     // NOTE: no unlock — the lock was never acquired
        }
        try {
            List<TenantProfile> tenantProfiles = tenantDbConfigurationRepository.findByActiveTrue().stream()
                .map(c -> new TenantProfile(c.getTenant().getName(), c.getWarehouse()))
                .toList();
            if (tenantProfiles.isEmpty()) {
                LOG.warn("No tenants configured — skipping pendingReversalReconcile");
                return;                 // the finally below still unlocks
            }
            for (TenantProfile tenantProfile : tenantProfiles) {
                try {
                    // ⚠ setCurrentTenant is INSIDE this catch on purpose (verbatim reasoning from
                    // RestIdempotencyCleanupJob): TenantContext dereferences getTenantName().length()
                    // whenever the facility code is non-null, so a landlord row with a null tenant
                    // name NPEs HERE — and without a loop-level catch that NPE aborts the run for
                    // every REMAINING tenant, not just this one.
                    TenantContext.setCurrentTenant(tenantProfile);
                    alertService.alertOnStalePendingReversals();
                } catch (Exception e) {
                    LOG.error("Error during pendingReversalReconcile for tenant {} - {}",
                        tenantProfile.getTenantName(), tenantProfile.getFacilityCode(), e);
                } finally {
                    TenantContext.clear();      // ALWAYS, per tenant, in a finally
                }
            }
        } finally {
            advisoryLockService.unlock(AdvisoryLockService.JobLockId.PENDING_REVERSAL_RECONCILE);
        }
    }
}
```

Non-obvious invariants this skeleton encodes:

1. **`tryLock` → `try` → `finally unlock`, and the early `return` on a failed `tryLock` is OUTSIDE
   the try.** `AdvisoryLockService.unlock` pins/unpins a `ThreadLocal<Connection>`; calling it
   without a prior successful `tryLock` logs `"unlock({}) called with no pinned connection"`.
2. **Never nest two locks of the same form on one thread.** Each form has exactly one
   pinned-connection slot; a second acquisition overwrites it and leaks the first connection *with
   its lock still held*. Lock → work → unlock → next tenant.
3. **Landlord connection budget.** The advisory lock pins a raw landlord JDBC connection for the
   whole tick, and `findByActiveTrue()` needs a second one **while that lock is held** — so this job
   costs **two landlord connections concurrently**, exactly like each outbox lane.
   `OutboxDispatcherJob:runLane`'s javadoc states the rule: do not let
   `landlord.datasource.maximum-pool-size` drop below `2 × (lanes) + headroom for the other eight
   advisory-locked jobs`. A nightly job at 02:30 is cheap, but it is not free.
4. **Transaction posture: the job method itself is NOT `@Transactional`.** No job in
   `schedulejob/` carries a class- or method-level `@Transactional`. The transaction boundary lives
   in the delegated service (`OutboxDispatchService`, `StaleClubBatchCleanupJobService`, …), which is
   where `@Transactional(value = "tenantTransactionManager", …)` goes. Putting it on the job method
   would hold one tenant transaction open across every tenant — and the tenant transaction manager is
   routed by `TenantContext`, which this loop changes underneath it.
5. **Two-level catch.** The *outer* per-tenant catch isolates tenants from each other; a *second*
   inner catch per independent sweep isolates the sweeps from each other. `RestIdempotencyCleanupJob`
   has both and says why in a comment; copy the shape if the job grows a second duty.
6. **`@Scheduled` cron with a default in the placeholder** (`${app.cron.x:0 30 2 * * *}`) — otherwise
   a missing property is a startup failure. `RestIdempotencyCleanupJob` uses the *undefaulted* form
   `"${app.cron.cleanup-rest-idempotency}"` and relies on `application.properties:163`; both outbox
   lanes use the defaulted form. Prefer the defaulted form.
7. **Fixed-phase second.** `SchedulingReconcileIdempotencyUnitTest` derives the set of occupied
   seconds from the annotations *and* from `application.properties` on disk and fails if second 50
   (the reconcile's) is among them. A new fixed-phase cron on second 50 breaks that test — which is
   the point of the test. Second 0 is already the busiest.

### 1.4 If Pattern D′ is chosen instead

A D′ job needs, additionally: a `static final String JOB_NAME`; a package-private
`TenantSchedule deriveSpecForCurrentTenant()` that throws `IllegalStateException` **before** any
sysprop read when `TenantContext.getCurrentTenant() == null` (with no context the routing datasource
falls back to the **landlord** DataSource where `los_sysprop` does not exist, so a guard placed after
the reads is unreachable in production); a `public void runFor(TriggerSpec spec)` entry point; a new
`configureXGroups(...)` in `SchedulingConfiguration` plus a `CONFIGURED_JOB_NAMES` entry; the
malformed-row guard *before* `TenantProfile` construction on both sides; `Math.toIntExact` on the
tenant id before `tryLock(job, tenantId)`; and — critically — **registration and fire time must call
the same `deriveSpecForCurrentTenant()`**, because a tenant whose registration-time spec differs from
its fire-time spec falls silently out of every group. Always build specs via `TriggerSpec.of(cron,
zone)`, never the canonical constructor, so the zone-invariant collapse is applied on both sides.

### 1.5 `JobMetrics`

`JobMetrics` is **not** a Spring bean per job by annotation — `JobMetricsConfiguration` declares one
`@Bean` per job, each with a distinct `jobSegment`, and *"Spring resolves the `jobMetrics` constructor
parameter on each job by matching the parameter name to the bean name produced by these `@Bean`
factory methods."* A new instrumented job therefore needs a new `@Bean` method whose **method name
matches the job's constructor parameter name**, or injection fails at context start.

Available surface: `markLastRun()` / `markLastSuccess()` gauges, `skippedLockBusy()`,
`skippedJvmBusy()`, `tenantSuccess(tenant)`, `tenantFailure(tenant, reason)`,
`tenantSkippedNotActivated(tenant)`, `rowsProcessed(tenant, n)`, `startTenantTimer()` /
`stopTenantTimer(...)`, `recordDuration(nanos)`.

⚠ **The most transferable design lesson in the whole class** is `JobMetrics`'s own javadoc on the
SBDEV-2961 pair, and it applies directly to F5:

> `tenantOrdersSkippedNoSection` — *"standing volume … Dashboard this; alert on
> `tenantOrdersMarkedNoSection` instead."*
> `tenantOrdersMarkedNoSection` — *"**This is the alert surface.** A per-tick counter would fire
> continuously from the moment the first mis-configured client exists until the data is backfilled,
> and an alert that is always red gets muted — which would defeat the point of the ticket."*

A naive F5 fires every night for the same 7 Hydra rows until someone completes them. That is an
always-red alert. **Separate standing volume from transitions** — see §4.7.

---

## 2. `wms2-scheduled-jobs-catalog.md` — reconciled against code

Doc: `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md`, `last_verified: 2026-09-06`
(SBDEV-3198 pass). It is in good shape — §2's four `AdvisoryLockService` method cites (`:76`, `:115`,
`:179`, `:215`) are **all exactly right today**, which is unusual for line cites in this vault. The
drift below is all one root cause: **the outbox CLUB lane (SBDEV-3310 era) landed after the last
verification pass and is invisible to the doc.**

| # | Where | Doc says | Code says | Why it matters |
|---|---|---|---|---|
| **D1** | §2, the `JobLockId` constants table (8 rows, ends at `100008L`) | last id is `JobLockId.OUTBOX_DISPATCHER = 100008L` | `OUTBOX_DISPATCHER_CLUB = 100009L` exists | **Directly harmful to this ticket.** An implementer picking "the next free id" from the catalog picks `100009` and collides with the club lane — a silent cross-job mutex, the exact class of bug §2 warns about. |
| **D2** | §2, method table | `tryLock(long lockId)` is used by *"**four** lock ids — `100007L`, `100008L`, and `100003L`/`100004L` as the outer half of a dual lock"* | **five**: `100009L` is a fifth one-key id | Undercounts the one-key population; the same sentence is the basis for "the one-key form did not become outbox/idempotency-only". |
| **D3** | §2, lock-shape table | `OutboxDispatcherJob` → *"one-key only, call sites `:59`/`:110`"* | one `runLane` is shared by **two** `@Scheduled` lanes with **two different lock ids**; current call sites are `:105` (`tryLock`) and `:166` (`unlock`) | A reader looking for the second lane's lock finds nothing. |
| **D4** | §1 | *"`wms2-api` runs **ten** recurring workloads in-process, in **three** gating classes"* | **twelve**: 6 registered `CronTrigger` jobs + 6 real `@Scheduled` annotation sites | Miscount of two: `OutboxDispatcherJob.dispatchClub` and `SchedulingConfiguration.reconcileSchedules` (the latter arrived with SBDEV-3198's own AC15 and was never added to the §1 count). |
| **D5** | §7.7 | quotes `app.cron.outbox-dispatcher=*/15 * * * * *` *"line 149"* | `application.properties:176` is **`*/3 * * * * *`**, and `:179` adds `app.cron.outbox-dispatcher-club=*/3 * * * * *`, which §7.7 does not mention | The tick rate is 5× what the doc says — material to the landlord-pool arithmetic §7.7 and §2 both rely on. Line 149 is now `app.cron=false`-adjacent commentary, not this key. |
| **D6** | §7.6 (via §548) | *"`StaleClubBatchCleanupJob` and `RestIdempotencyCleanupJob` are a parity gap — not instrumented"* | still true, **and** `OutboxDispatcherJob`'s hand-rolled meters (`wms2.outbox.tick_duration`, two `MultiGauge`s) are not in the §7.6 inventory either | Minor, but the "metrics per job" list reads as exhaustive and is not. |

**Not drift, worth quoting** — §7.7 is correct and is the single most important line for F5:

> Setting `app.cron=false` does **not** stop `OutboxDispatcherJob` or `RestIdempotencyCleanupJob`. …
> To stop them you must change their cron expression; there is no off switch.

That cuts both ways and is the crux of §3 and §4.6: a Pattern A job **cannot be silently switched off
by a tenant-side sysprop**, and it also **cannot be switched off at all** without a deploy.

**Method / blind spots for this reconciliation.** I read §1, §2, §3.1–3.4, §6, §7.7–7.10 and §10 in
full and compared each factual claim against the source file it cites. I did **not** re-verify §4's
per-job subsections (4.1–4.8) or §5, and the doc itself flags §6 and §4's read/write inventories as
not re-derived on the 2026-09-06 pass — so absence of a D-row for those sections is "not checked",
not "verified clean".

---

## 3. The per-tenant cron landmine

### 3.1 The mechanism, in code

`NEW_CRON_JOB_ACTIVATED` is a **tenant-DB `los_sysprop` row**, not a Spring property.
`WmsConstants:1256-1257`:

```java
public static final String SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY = "NEW_CRON_JOB_ACTIVATED";
public static final String SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_DEFAULT_VALUE = "true";
```

It is read by **six** classes in `src/main` — the six `SchedulingConfiguration` jobs — plus
`UtilRestController` (the admin "run now" surface).
Method: `grep -rln "SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY" src/main` → 8 files, of which one is
`WmsConstants` (the declaration) and one is `UtilRestController`. Blind spot: a caller using the
string literal `"NEW_CRON_JOB_ACTIVATED"` instead of the constant would be missed — `grep -rn` on the
bare literal over `src/main` returns only `WmsConstants.java` and the two SQL seed files, so there is
no such caller today.

The shape at every call site is `StaleClubBatchCleanupJob`'s:

```java
if (!Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY))
    || !Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_ACTIVATED_KEY))) {
    LOG.info("{} not activated for {} - {}", JOB_NAME, profile.getTenantName(), profile.getFacilityCode());
    continue;
}
```

**Three ways this fails silently, all of them live:**

1. **`Boolean.parseBoolean(null)` is `false`.** `SyspropService.getSysvalue` →
   `SyspropRepository.findSysvalueBySyskey`, a native query
   `"select sysvalue from los_sysprop where syskey = :syskey and workstation = 'DEFAULT' order by
   client_id LIMIT 1"`, which returns **`null` when the row is absent**. So a **missing** sysprop row
   is indistinguishable from `'false'` — the gate **fails CLOSED**. A new job that copies this shape
   and forgets its seed migration is inert on every tenant, forever, with one INFO line per tenant
   per night as the only evidence.
2. **The skip logs at INFO and increments `tenantSkippedNotActivated`**, which nothing scrapes (§4.1).
3. **A cutover writes the row.** The in-repo seed is `'true'` in **both**
   `db/migration/V2.2.00__base_v2_schema.sql:2679` and the v1→v2 onboarding
   `db/v1-to-v2-onboarding/schema/V1.0.04__wms_init_data.sql:148`. On SBDEV-3288 (ShipItEZ C1WH UAT,
   2026-09-09) the live value was `'false'` — written by **out-of-repo cutover tooling**, identifiable
   because `los_sysprop.modified` was byte-identical across 19 rows (the same write that repointed
   every `WEBSERVICE_*` URL). Symptom: orders searchable but stuck at `customerorder.state = 0` for
   days. `ORDER_TIMER_ACTIVATED = 'true'` looked correct and proved nothing.

Also note `SyspropService.getSysvalue` is `@Cacheable(value = "sysprops", …)` keyed on
`TenantKeyBuilder.cacheKey(TenantContext.getCurrentTenant()) + ':' + key`, and a **direct SQL
`UPDATE` does not evict that cache** — but the observed SBDEV-3288 fix took effect on the next tick
23 s later without a restart, so the TTL is short. Use the admin sysprop endpoint if you want
determinism.

### 3.2 Current state across every reachable v2 tenant DB (measured 2026-09-16)

| MCP server | database | `NEW_CRON_JOB_ACTIVATED` | `System Time Zone` |
|---|---|---|---|
| `wms2-hydra` (**PRD**) | `wh01_hydra_v2` | **`true`** | `America/New_York` |
| `nywh-hydra-uat` | `wh01_hydra_v2` | `true` | `America/New_York` |
| `c1wh-shipitez-uat` | `wh01_shipitez_v2` | `true` | `America/Los_Angeles` |
| `nywh-shipitez-uat` | `wh02_shipitez_v2` | `true` | `America/New_York` |
| `wsl-wineco-uat` | `wh01_om1_v2` | `true` | `America/Los_Angeles` |
| `wms2-wineco-dev` | `dev_wh01_om1` | `true` | `America/Los_Angeles` |

Six of six are `true` — the SBDEV-3288 outlier has been repaired. The landmine is **structurally
live for the next cutover**, not currently armed. (Scope of this claim: the six tenant DBs I have
MCP access to. There may be tenant DBs I cannot reach; I did not enumerate `tenant_db_configuration`
on all three landlords to check.)

On Hydra PRD specifically:

```
syskey                             sysvalue           workstation  groupname         modified
NEW_CRON_JOB_ACTIVATED             true               DEFAULT      System Settings   2021-07-12 14:36:29.727+00
OLD_CRON_JOB_ACTIVATED             VERSION-1.0-ONLY   DEFAULT      System Settings   2021-07-12 14:36:29.727+00
CRON_JOB_SHOW_LOG                  false              DEFAULT      Backend           2021-07-12 14:36:29.727+00
STALE_CLUB_BATCH_CLEANUP_ACTIVATED false              DEFAULT      Backend           2026-06-11 21:44:21.119+00
STOCK_SUMMARY_EXPORT_TIMER_ACTIVATED true             DEFAULT      System Settings   2021-07-12 14:36:29.776+00
System Time Zone                   America/New_York   DEFAULT      System Settings   2021-07-12 14:36:29.727+00
```

⚠ Note `OLD_CRON_JOB_ACTIVATED = 'VERSION-1.0-ONLY'` — a non-boolean string in a boolean-named
sysprop. `Boolean.parseBoolean` renders it `false`, which is the intended effect, but it is a
reminder that these columns are free text.

### 3.3 What a new job needs seeded — per pattern

**Pattern A (recommended):** **nothing.** A Pattern A job reads no tenant sysprop gate and is
therefore immune to the entire landmine above. If you want a tunable threshold, seed **one** row and
read it through `SyspropService.getIntValue(key, default)`, which already falls back on
null/blank/non-numeric:

```java
public int getIntValue(String key, int defaultValue) {
    String value = getSysvalue(key);
    if (value == null || value.isBlank()) return defaultValue;
    try { return Integer.parseInt(value.trim()); } catch (NumberFormatException ignore) { return defaultValue; }
}
```

**Pattern D′:** **four** rows per tenant, and all four are mandatory:

| syskey | value | absent ⇒ |
|---|---|---|
| `NEW_CRON_JOB_ACTIVATED` | `true` | job skipped (`parseBoolean(null)` = false) — already present everywhere |
| `<JOB>_TIMER_HOUR` | e.g. `2` | `deriveSpecForCurrentTenant()` returns `null` ⇒ **tenant is in no group and gets no trigger at all** |
| `<JOB>_TIMER_MINUTE` | e.g. `30` | same |
| `<JOB>_ACTIVATED` | `true` | job skipped after taking the lock |

Plus `System Time Zone` (present on all six) — a null/blank/invalid value makes `TimezoneService`
fall back to **UTC with a WARN**, which for a US warehouse moves a 03:00 job to 22:00/23:00 local the
*previous evening*.

### 3.4 The seed migration

Next free Flyway version is **`V2.2.32`**. Local `db/migration/` tops out at
`V2.2.31__cancellation_log_pickingorder_position_id.sql`; I swept **every remote branch**
(`for b in $(git branch -r ...); do git ls-tree -r --name-only "$b" -- src/main/resources/db/migration; done`)
and `V2.2.31` is the global high-water mark, so no unmerged branch is sitting on 32. (Blind spot from
memory `flyway-collision-sweep-cannot-catch-a-branch-pushed-later`: re-run the sweep immediately
before opening the PR — a branch pushed after this scan is invisible to it.)

Copy `V2.2.29__seed_clubline_oms_chunk_size_sysprop.sql` exactly. Its three load-bearing properties:

- **Guard on `(syskey, workstation = 'DEFAULT')`, not syskey alone** — *"the runtime read is
  `SyspropRepository.findSysvalueBySyskey`, which filters on `workstation='DEFAULT'`, so a syskey-only
  guard could be satisfied by a row the runtime never reads."*
- **`description` must be under 255 chars** — `los_sysprop.description` is `varchar(255)` and
  Postgres raises 22001 rather than truncating, **aborting the whole migration file**.
- **The literal default is duplicated from a `WmsConstants` `*_DEFAULT_VALUE`** (SQL cannot read a
  Java constant, and a Flyway file is immutable once applied) — so add a consistency test pinning the
  two together, as `ClublineOmsChunkSizeSeedConsistencyTest` does.

Cross-check against `sbdocs/1-Projects/wms2/plan/SBDEV-3198-per-tenant-cron-scheduling.md`
(`status: implemented — all 6 jobs on the D′ shape and MERGED to develop`): the plan explicitly
budgets the gate reads — *"the jobs already open each tenant's context and read
`NEW_CRON_JOB_ACTIVATED` + `*_TIMER_ACTIVATED` per tenant per tick, so two more cached sysprop reads
are marginal"* — and its remaining open items (AC1/AC2 UAT boot-log verification, AC5 `app.cron=true`
singleton, AC7 pool cap) are **environment facts, not code work**. Two of them touch F5: **AC5 is
unverified**, i.e. nobody has confirmed that exactly one prd container carries `app.cron=true`. A
Pattern D′ F5 inherits that unverified assumption; a Pattern A F5 does not (its advisory lock is the
guarantee, not a Portainer setting).

---

## 4. What "alert" means here — the crux

### 4.1 Does anything scrape Prometheus? **No. Measured today, first-hand.**

Three independent instruments, all agreeing:

1. **The endpoint is live but authenticated.** Measured 2026-09-16 against prd:
   `GET https://wms-api.sbo.li/api/public/version` → **200**
   (`{"environment":"PRD","self":{"repository":"wms2-api","version":"0.0.26"},"drift":false}`) —
   this is the positive control proving the host is reachable and the probe works.
   `GET https://wms-api.sbo.li/actuator/prometheus` → **401**.
   `SecurityConfiguration:146-147`: only `/actuator/health/**` and `/actuator/info` are `permitAll()`;
   everything else under `/actuator/**` requires `hasAnyAuthority("ADMIN", Authority.WMS_ADMIN_ROLE)`.
   A Prometheus scrape job would need a bearer token it has no way to refresh.
2. **No scrape configuration exists anywhere in the estate repos.** `find` for
   `*prometheus*`/`*grafana*`/`*alertmanager*`/`scrape*` across the whole monorepo returns **7 hits,
   all of them inside `vendor/aws/aws-sdk-php/` in a worktree** (`ManagedGrafanaClient.php`,
   `PrometheusServiceClient.php`, …) — an unrelated SDK. Zero config files.
3. **The codebase's own plans say so, repeatedly and recently.** `SBDEV-3339` §5.2/§6, prerequisite 5:
   *"a Micrometer counter is published but **nothing scrapes Prometheus yet**, so the log is the
   operative control"*; its architect review adds *"logs are not queryable five weeks later"*. Two
   SBDEV-3198 review lanes say the same. Memory `wms2-metrics-exist-but-nothing-scrapes-them`
   (2026-09-02) records Joe owns infra and *"a metric is NOT a working control"*.

**Blind spot, stated plainly:** I can see the application repos and the public internet. I cannot see
Portainer, the reverse proxy config, or any infra repo. It is *conceivable* that a scraper exists
outside my view with a static token. Three converging instruments plus a 401 make that unlikely, and
nobody on the team has ever claimed one exists. **Treat "a metric is an alert" as false until someone
shows a dashboard.**

### 4.2 Email: **does not exist in this codebase at all**

`grep -rn "JavaMailSender\|MailSender\|smtp\|javax.mail\|jakarta.mail" src/main pom.xml` → **zero
hits.** (Positive control for the instrument: a `grep -rlc "HttpRestService" src/main/.../service/*.java`
on the same tree returns files, so grep is working and the zero is a true zero, not a broken scan.
Residual blind spot: mail sent over a vendor HTTP API rather than SMTP would not match these tokens —
but `grep -rn -i "sendgrid\|mailgun\|twilio\|pagerduty\|opsgenie\|slack\|webhook\|teams\.microsoft"`
over `src/main` is also empty.)

**So F5 as literally written — "emails ops" — cannot be implemented without adding
`spring-boot-starter-mail`, SMTP credentials per environment, and a per-tenant recipient list.** That
is a new external dependency and a new secret in a repo that has had two credential incidents
(SBDEV-3175, SBDEV-3194). Do not do it for this ticket.

### 4.3 Channels that actually exist and work

| Channel | Mechanism | Reaches a human? | Cost |
|---|---|---|---|
| **Service Log row** | `MessageService.createServiceLog(...)` → `Message` row → the **Service Log screen in the WMS Web UI** | **Yes, on pull.** Durable, queryable months later, per-tenant, already the forensic surface every cancel/OMS flow writes to | Zero new deps. ⚠ `createServiceLog` is `@Transactional(REQUIRES_NEW)` and resolves the operator from `SecurityContextUtils.getUserName()`, falling back to `USER_ANONYMOUS` — correct for a cron with no principal |
| **OMS outbox** | `OutboxService.enqueue(OutboxMessage)`, `MANDATORY` propagation, drained by `OutboxDispatcherJob` every 3 s | Only if OMS builds a handler | Cross-repo: a new `process_type`, a new `WEBSERVICE_*` URL sysprop per tenant, and OMS-side work. The existing `ORDER_BATCH_REVERSAL_COMPLETED` (`WmsConstants:495`, URL sysprop `:1176`) is the precedent — and SBDEV-1921's F1 shows agreeing a new OMS contract is a quarter-long item |
| **ERROR/WARN log** | slf4j | Only if someone is tailing, and **not queryable at the horizon that matters** — the 63 units went 47 days | Zero |
| **Micrometer gauge/counter** | `JobMetrics` or a `MeterRegistry` | **No.** See §4.1 | Near-zero |
| **The mobile screen that already exists** | `GET /v3/cancellation/list` → `CancellationReversalService.listPendingReversals()`, gated by `@RequiresFunction(MOBILE_UI_VIEW_CANCELLATION)`, rendered by `wms2-mobile-ui/components/cancellation/cancellationAction.vue` | **Yes — for the person who can actually fix it** — but only if they open the screen | Zero backend work; a UI badge is small |

### 4.4 The honest diagnosis

**The pending list was never invisible.** `/v3/cancellation/list` and `cancellationAction.vue` have
existed since SBDEV-1921 Phase 3. The 63 units sat for 47 days not because the data was unreachable
but because **every surface in this system is pull, and nobody pulled.** A reconciliation job that
adds a sixth pull surface does not by itself change that outcome.

### 4.5 Recommendation

**Ship all three tiers; be explicit about which one is the control.**

1. **Primary — a Service Log row per tenant per occurrence, via `MessageService.createServiceLog`.**
   This is the only channel that is (a) already working, (b) per-tenant, (c) durable past the
   five-week horizon at which these defects actually get found, and (d) reachable by a warehouse
   supervisor without an infra ticket. Suggested shape:
   `sender = WMS_INSTANCE_NAME`, `receiver = "OPS"`, `process = "PENDING_REVERSAL_RECONCILE"`,
   `status = MessageStatus.CREATED`, message body naming the count, the oldest age in hours, and the
   affected tote labels and order ids — so the row is actionable without a second query.
2. **Secondary — one `LOG.error(...)` line** with the same content, for anyone tailing or shipping
   logs. Not the control; a breadcrumb.
3. **Tertiary — a `MultiGauge` `wms2.cancellation.pending_reversals{tenant,facility}` plus
   `...oldest_age_hours`,** modelled on `OutboxDispatcherJob`'s `stuckAggregateGauge`. Wire it now so
   that the day a scraper appears this is already there. **Do not call it the alert.**

**Its weakness, stated plainly:** the Service Log is **still pull**. It moves the discovery horizon
from "a customer complains" to "someone opens the Service Log", which on this estate is days, not
minutes. It does not page anyone. Nothing in `wms2-api` can page anyone today.

**The complement that would actually close the loop** (out of this lane's scope, worth proposing on
the ticket): a **count badge on the mobile Cancellation menu entry**, fed by the existing
`GET /v3/cancellation/list`. That is the only channel that reaches the person holding the scanner who
can complete the reversal, it needs zero backend work, and it is F4's spirit executed against a
surface that exists rather than against a Grafana nobody runs.

### 4.6 Which scheduling pattern — **Pattern A**

The whole purpose of F5 is to be a **watchdog**. A watchdog must not sit behind the same per-tenant
activation machinery whose silent failure it is supposed to catch. Pattern D′ puts **three** gates in
front of it — `app.cron=true` on exactly one replica (**SBDEV-3198 AC5: unverified on prd**),
`NEW_CRON_JOB_ACTIVATED` (**demonstrated to arrive as `false` from cutover tooling**, SBDEV-3288), and
its own `*_ACTIVATED` row (**absent ⇒ `parseBoolean(null)` ⇒ false**) — any one of which makes it
silently inert, which is precisely the failure it exists to detect. Pattern A has none of them.

Accept Pattern A's costs knowingly: it runs on every replica (the one-key advisory lock is the
guarantee — and it *is* a real guarantee, since `AdvisoryLockService` pins the raw connection in a
`ThreadLocal` so `pg_try_advisory_lock` and `pg_advisory_unlock` run on the same PG session); it has
one fleet-wide firing time rather than per-tenant local time (fine for a nightly digest, and
`RestIdempotencyCleanupJob` sets the precedent at `0 0 2 * * *`); and it has **no off switch short of
a deploy** (§7.7). That last one is a feature here.

### 4.7 Alert hygiene — do not ship an always-red alert

Hydra's 7 rows are **blocked on a release, not on attention** — per
`sbdocs/2-Areas/runbooks/free-63-units-t0002-t0007.md`, the fixes are on `develop` and PRD runs
`main`. A nightly alert would fire for them every night until that release lands, and then get muted.
Follow `JobMetrics`'s own SBDEV-2961 precedent:

- **Gauge = standing volume** (current pending count and oldest age) — for a dashboard.
- **Service Log row = transition** — write it when the *set* of over-threshold rows **changes**
  (a new id crosses the threshold), or at most one digest row per tenant per day, and say in the body
  how many are *new since the last occurrence*.

---

## 5. The query

### 5.1 Which column dates a row — **`created_at`, and this is not a free choice**

Verified in `model/CustomerorderCancellationLog.java` and confirmed against live data:

- **`created_at`** (`@Column(name = "created_at", nullable = false)`) is stamped unconditionally on
  every row: `CancellationLogService.java:78` → `log.setCreatedAt(OffsetDateTime.now());`, two lines
  after `log.setReversalRequired(reversalRequired);`.
- **`reversal_initiated_at`** is stamped **only when an operator opens the reversal**:
  `CancellationReversalService.java:179`, inside `initiateReversal(...)`, guarded by
  `if (log.getReversalInitiatedAt() == null)`.

**Therefore an age bound on `reversal_initiated_at` is vacuous for exactly the population that needs
alerting.** Measured on Hydra PRD: **7 of 7 pending rows have `reversal_initiated_at IS NULL`**, and
`NULL < cutoff` evaluates to UNKNOWN, so such a query returns **zero rows forever** — a green,
confident, useless job. Use `created_at`.

A tempting refinement, **rejected**: `COALESCE(reversal_initiated_at, created_at) < :cutoff` would
"reset the clock" when someone starts a reversal. Don't. An operator who initiated a reversal and
abandoned it is the case you most want surfaced, and across all six reachable DBs the
initiated-but-not-completed population is **0 rows**, so the refinement buys nothing and costs the
one case it would hide. Instead, **report** `reversal_initiated_at` in the alert body
("touched on <date>, never completed").

Index support already exists — `V2.2.00__base_v2_schema.sql:3869`:

```sql
CREATE INDEX idx_cancel_log_reversal_pending ON public.customerorder_cancellation_log
  USING btree (tenant_name, facility_code, reversal_required, reversal_completed_at)
  WHERE ((reversal_required = true) AND (reversal_completed_at IS NULL));
```

`created_at` is not in it, so the age predicate is a filter on top of the partial index. Irrelevant at
this cardinality (16 rows estate-wide on the largest tenant); **no new index needed.**

### 5.2 The repository method — JPQL, threshold bound from Java

```java
@Query("SELECT l FROM CustomerorderCancellationLog l "
     + "WHERE l.reversalRequired = true "
     + "AND l.reversalCompletedAt IS NULL "
     + "AND l.createdAt < :cutoff "
     + "ORDER BY l.createdAt")
List<CustomerorderCancellationLog> findPendingReversalsOlderThan(@Param("cutoff") OffsetDateTime cutoff);
```

with the cutoff computed in the service, exactly as `RestIdempotencyCleanupJob` computes its
retention cutoff (`Instant cutoff = Instant.now().minus(RETENTION_DAYS, ChronoUnit.DAYS);`):

```java
int hours = syspropService.getIntValue(
        WmsConstants.SYSTEM_PROPERTY_CANCELLATION_REVERSAL_ALERT_AGE_HOURS_KEY, 24);  // fails OPEN
OffsetDateTime cutoff = OffsetDateTime.now().minusHours(Math.max(hours, 1));
```

**Why JPQL with a bound parameter and not native SQL:** `make_interval(hours => …)` and
`now() - interval` are PostgreSQL-only. `src/test/resources/application-integration.properties`
points both the landlord and the tenant datasource at
`jdbc:h2:mem:wms_integration;…;MODE=PostgreSQL` with `spring.jpa.database-platform=H2Dialect`, so a
native Postgres-only predicate is **untestable in the H2 lane** and only reachable from a
Testcontainers test. Binding an `OffsetDateTime` computed in Java makes the query portable, keeps the
threshold in one place, and lets the H2 lane test it. **This is the single most consequential shape
decision in §5.**

**Fail-open, deliberately.** `getIntValue` returns the default on null/blank/non-numeric, so a missing
or fat-fingered sysprop yields a working 24 h alert rather than a silent one. `Math.max(hours, 1)`
mirrors `RestIdempotencyCleanupJob.safeOutboxRetentionDays()`'s floor-don't-throw reasoning — a
mistyped threshold must not take the watchdog offline. (Per memory
`enhancement-paths-must-fail-open-on-missing-config`: do **not** copy the
`Boolean.parseBoolean(getSysvalue(...))` gate shape here — it fails closed.)

### 5.3 Equivalent SQL, run live against Hydra PRD

**Query, verbatim** (`mcp__wms2-hydra__execute_sql`, 2026-09-16):

```sql
SELECT id, customerorder_id, customerorder_position_id, amount_picked, tote_label_id,
       created_at, reversal_initiated_at, reversal_completed_at,
       round(EXTRACT(EPOCH FROM (now() - created_at))/3600.0, 1) AS age_hours
FROM public.customerorder_cancellation_log
WHERE reversal_required = true
  AND reversal_completed_at IS NULL
  AND created_at < now() - make_interval(hours => 24)
ORDER BY created_at;
```

**Result — 7 rows, verbatim** (`wh01_hydra_v2`):

| id | customerorder_id | co_position_id | amount_picked | tote | created_at (UTC) | initiated | completed | age_hours |
|---|---|---|---|---|---|---|---|---|
| 1 | 60861 | 60864 | 24.0000 | `T-0002` | 2026-07-31 15:52:44.031607 | NULL | NULL | **1128.6** |
| 2 | 60861 | 60863 | 12.0000 | `T-0002` | 2026-07-31 15:52:44.067489 | NULL | NULL | 1128.6 |
| 3 | 60861 | 60865 | 12.0000 | `T-0002` | 2026-07-31 15:52:44.079971 | NULL | NULL | 1128.6 |
| 4 | 60861 | 60862 | 12.0000 | `T-0002` | 2026-07-31 15:52:44.092264 | NULL | NULL | 1128.6 |
| 8 | 159907 | 159909 | 1.0000 | `T-0007` | 2026-09-04 19:15:03.398811 | NULL | NULL | 285.2 |
| 9 | 159907 | 159910 | 1.0000 | `T-0007` | 2026-09-04 19:15:03.434852 | NULL | NULL | 285.2 |
| 10 | 159907 | 159908 | 1.0000 | `T-0007` | 2026-09-04 19:15:03.449246 | NULL | NULL | 285.2 |

**24 + 12 + 12 + 12 + 1 + 1 + 1 = 63 units. 1128.6 h = 47.0 days.** This is exactly the population the
ticket names, and it matches `sbdocs/2-Areas/runbooks/free-63-units-t0002-t0007.md` row for row. The
job would have fired on **1 August 2026**.

Aggregate context on the same DB:

```
total_rows=16  reversal_required=7  pending=7  pending_never_initiated=7
oldest_created=2026-07-31 15:52:44+00  newest_created=2026-09-10 20:37:02+00
```

### 5.4 Positive control — a zero that is provably a true zero

A count of 0 on an **empty table** proves nothing (a broken query and an empty table look identical).
`nywh-hydra-uat` returns `total_rows = 0`, so it is **not** a usable control and I discarded it.

**`wms2-wineco-dev` (`dev_wh01_om1`) is the real control** — it has rows, has rows matching the first
predicate leg, and still returns zero:

```
total_rows = 8      reversal_required_rows = 5      pending_any_age = 0      pending_over_24h = 0
```

Row detail confirming the discrimination on **both** legs (so neither predicate is a no-op):

| id | reversal_required | created_at | initiated | completed | age_hours |
|---|---|---|---|---|---|
| 1 | **true** | 2026-05-28 19:31:24 | 2026-05-28 19:50:56 | **2026-05-28 20:42:24** | 2660.9 |
| 2 | true | 2026-05-28 23:17:45 | 2026-05-28 23:20:06 | **2026-05-28 23:20:20** | 2657.2 |
| 3 | true | 2026-05-28 23:27:06 | 2026-05-28 23:28:34 | **2026-05-29 17:14:42** | 2657.0 |
| 4 | true | 2026-05-28 23:27:06 | 2026-05-28 23:28:34 | **2026-05-29 17:14:42** | 2657.0 |
| 5 | true | 2026-05-29 17:12:40 | 2026-09-11 21:08:01 | **2026-09-11 21:08:09** | 2639.2 |
| 6 | **false** | 2026-08-06 20:46:31 | NULL | NULL | 979.7 |
| 7 | false | 2026-08-06 20:46:31 | NULL | NULL | 979.7 |
| 8 | false | 2026-08-06 20:46:31 | NULL | NULL | 979.7 |

Five rows are `reversal_required = true` and *every one* has `reversal_completed_at` set — rows 1–5
are excluded by the **completion** leg, rows 6–8 by the **required** leg, and all eight are far older
than 24 h so the **age** leg excludes nothing. The query discriminates; the zero is real.
(Row 5 is the SBDEV-3316 Phase A rehearsal, completed 2026-09-11 21:08 — the runbook's recorded run.)

Same query on the other four tenants, all true zeros of the empty-table kind (recorded for
completeness, **not** as controls): `nywh-hydra-uat` 0/0, `c1wh-shipitez-uat` 0/0,
`nywh-shipitez-uat` 0/0, `wsl-wineco-uat` 0/0.

**Conclusion: today, across the entire reachable v2 estate, exactly one tenant (Hydra PRD) has any
pending reversal at all, and all 7 of its rows are >24 h old.** Scope of "entire": the six tenant DBs
I have MCP access to; I did not enumerate `tenant_db_configuration` across all three landlords to
prove those six are all of them.

### 5.5 Reachability caveat for the MCP probes

Three of the seven MCP calls failed first with
`"consuming input failed: server closed the connection unexpectedly"` and succeeded verbatim on
immediate retry (`nywh-hydra-uat`, `wsl-wineco-uat`, `wms2-wineco-dev`). This is the known
first-query-after-idle drop, not a DB fault. Every number above is from a successful call.

---

## 6. Test surface

### 6.1 How a scheduled job is tested here — plain Mockito unit tests, no Spring context

**28 job test classes**, split across two packages (`ls` of both directories; blind spot: a job test
living outside these two packages would be missed — `OutboxDispatchService`'s own tests, for example,
sit under `unit/service/job/`):

`src/test/java/net/aim_ai/wms/schedulejob/` (4) — `SchedulingConfigurationUnitTest`,
`SchedulingReconcileIdempotencyUnitTest`, `StaleClubBatchCleanupJobDeriveSpecUnitTest`,
`TriggerSpecUnitTest`.

`src/test/java/net/aim_ai/wms/unit/schedulejob/` (24) — per job, typically a `…JobUnitTest` (the TDD
gate), a `…JobTest` (behaviour), a `…JobMetricsUnitTest`, plus topic-specific ones
(`OrderReleaseJobStreamingTest`, `ReplenishOrderJobPaginationTest`,
`ReplenishOrderJobConnectionBudgetTest`, `StockSummaryExportJobOmsDecouplingTest`,
`StockSummaryExportJobBulkInsertTest`, `OrderReleaseJobSectionGuardTest`), plus the cross-cutting
`JobMetricsUnitTest`, `WholeRunSuccessGaugeUnitTest`, `AdminTriggerTenantScopeUnitTest`,
`OutboxDispatcherJobUnitTest`, `RestIdempotencyCleanupJobUnitTest`.

**The pattern** (closest model: `StaleClubBatchCleanupJobUnitTest`, 480 lines):

- `extends BaseServiceUnitTest`, `@MockitoSettings(strictness = Strictness.STRICT_STUBS)`.
- `@Mock` every collaborator (`AdvisoryLockService`, `TenantDbConfigurationRepository`,
  `SyspropService`, `TimezoneService`, the delegated service), `@InjectMocks` the job.
- **Assert the lock explicitly**, both id and form:
  `verify(advisoryLockService).tryLock(eq(JOB), eq(tenantId))` and the matching `unlock`;
  `inOrder(...)` to pin lock-before-work.
- **Capture logs with logback's `ListAppender<ILoggingEvent>`** when the log line *is* the behaviour.
  Directly relevant: if the Service Log row is the alert, assert the `MessageService.createServiceLog`
  call with an `ArgumentCaptor`, not the log line.
- **Stub sysprops CONTEXT-SENSITIVELY.** Verbatim from that class: *"Every sysprop stub is
  CONTEXT-SENSITIVE — it answers from a per-facility table and returns null with no `TenantContext` —
  because a context-blind stub would let a dropped `setCurrentTenant` pass unnoticed (the regression
  PIT caught on the boot probe)."* A flat `when(sysprop.getSysvalue(K)).thenReturn("true")` cannot
  detect a missing `TenantContext.setCurrentTenant` and will green-light a job that routes to the
  landlord DB in production.
- ⚠ **`never()` on a primitive-arg method needs `anyLong()`, not `any()`.** `tryLock(long, long)`
  declares primitive longs; `any()` returns `null` and NPEs at unboxing *before* the verification
  runs. `NeverMatcherNullBlindnessArchTest` inventories these sites — a new one must comply.

### 6.2 Integration lanes and the native-SQL constraint

Two full-context lanes exist. The **MockMvc/H2 lane** (`application-integration.properties`) points
both datasources at `jdbc:h2:mem:wms_integration;DB_CLOSE_DELAY=-1;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE`
with `spring.jpa.database-platform=org.hibernate.dialect.H2Dialect`, and **tests must not run Flyway
against it**. The **Testcontainers lane** (`application-postgres-integration.properties`,
`org.testcontainers` in `pom.xml`) runs real PostgreSQL.

**Consequence for F5:** keep the age predicate in **JPQL with a bound `OffsetDateTime`** (§5.2) and
the whole thing is testable in the cheap H2 lane. Reach for native SQL — `make_interval`,
`EXTRACT(EPOCH …)`, `now() - interval '24 hours'`, `FOR UPDATE SKIP LOCKED` — and the test **must**
move to Testcontainers or it silently tests nothing.

Two lane traps worth restating from `CLAUDE.md` before trusting a green:
- `mvn failsafe:integration-test -Dit.test=<Class>` reports `Tests run: 0` and **BUILD SUCCESS** for
  any class. Use `mvn verify -Dit.test=… -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false`.
- An outer-level `@Test` in a class that also has `@Nested` classes is reported under a *nested*
  report file, and the outer class's own `.txt` reads `Tests run: 0`. Confirm via the lane total or
  `grep -rl '<methodName>' target/failsafe-reports/`.

### 6.3 Minimum test set for F5

| # | Test | Kills |
|---|---|---|
| 1 | `reconcile` acquires `tryLock(PENDING_REVERSAL_RECONCILE)` **before** any repository call, and `unlock`s in a `finally` even when the per-tenant work throws | lock-leak; a pinned landlord connection held forever |
| 2 | `tryLock` returning `false` ⇒ zero repository interaction **and** no `unlock` | double-execution across replicas; `unlock`-without-`tryLock` |
| 3 | tenant 1 throwing does **not** prevent tenant 2 from being processed | the whole class of "one bad landlord row kills the nightly run" |
| 4 | `TenantContext` is cleared after **every** tenant including the throwing one | context leak into the next tenant's queries |
| 5 | a row at `cutoff − 1s` alerts, a row at `cutoff + 1s` does not | off-by-one / wrong comparison direction |
| 6 | a row with `reversal_completed_at` set is **excluded** even when ancient | a dropped completion leg (the wineco-dev control's whole population) |
| 7 | a row with `reversal_initiated_at` set but `reversal_completed_at` null **is still alerted** | someone "fixing" §5.1's rejected `COALESCE` refinement back in |
| 8 | threshold sysprop absent / blank / `"abc"` / `"0"` / `"-5"` ⇒ still alerts at a sane bound | fail-closed regression — the §3.1 landmine reintroduced via the new sysprop |
| 9 | `createServiceLog` is called with the count, oldest age and tote labels (`ArgumentCaptor`) | the alert silently degrading to a log line |
| 10 | zero stale rows ⇒ **no** Service Log row written | alert-fatigue / an always-writing job |

**Mutation-check every one of these** (the five-item floor): break what the assertion protects and
confirm red. Test 5 in particular needs fixtures on **both** sides of the boundary — a fixture set
entirely in the dominant band cannot kill a `<` → `<=` mutant.

---

## 7. Summary for the plan author

| Decision | Recommendation | Strength |
|---|---|---|
| Scheduling pattern | **Pattern A** (`@Scheduled` + one-key advisory lock), modelled on `RestIdempotencyCleanupJob` | **High** — D′'s three gates are the failure mode F5 exists to catch, and SBDEV-3198 AC5 is unverified on prd |
| Lock id | **`JobLockId.PENDING_REVERSAL_RECONCILE = 100010L`** | **High** — `100009L` is taken by the club lane and the catalog does not say so |
| Cron | `app.cron.pending-reversal-reconcile`, default `0 30 2 * * *` (second 0 is the busiest; **not** second 50) | Medium |
| Age column | **`created_at`** | **High** — `reversal_initiated_at` is NULL on 7/7 pending PRD rows, so that bound is vacuous |
| Threshold | sysprop via `getIntValue(key, 24)` + `Math.max(hours, 1)` — **fails open** | **High** |
| Query form | **JPQL, `OffsetDateTime` bound from Java** | **High** — native Postgres date arithmetic is untestable in the H2 lane |
| Alert channel | **Service Log row** (primary) + ERROR log (secondary) + `MultiGauge` (tertiary, explicitly not the control) | **High on the negative** (nothing scrapes; no mail exists); **medium on the positive** — the Service Log is still pull |
| Flyway | `V2.2.32`, shaped on `V2.2.29`; re-sweep remote branches immediately before the PR | High |
| New index | **none** | High — partial index exists; 16 rows on the largest tenant |
| Complement to propose | **count badge on the mobile Cancellation menu**, fed by the existing `GET /v3/cancellation/list` | Medium — out of scope here, but it is the only channel that reaches the person who can complete the reversal |

**Two things a plan must not claim.** (1) That a Micrometer metric is an alert — `/actuator/prometheus`
returned **401** on prd today and no scrape config exists in any estate repo. (2) That F5 "emails ops"
as written — `wms2-api` has **zero** mail capability and adding SMTP is a new dependency and a new
secret, not a line of code.
