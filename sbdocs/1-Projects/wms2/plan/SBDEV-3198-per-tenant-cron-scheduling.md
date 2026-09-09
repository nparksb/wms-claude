---
title: "SBDEV-3198 — Per-tenant cron scheduling (SBDEV-3191 Slice B)"
type: plan
status: implemented — all 6 jobs on the D′ shape and MERGED to develop (StaleClubBatchCleanupJob #286/#287, StockSummaryExportJob #288, CleanUpOldMessagesJob #291 +#296, ReleaseExpiredPickingOrdersFromUserJob #293, OrderReleaseJob #301, ReplenishOrderJob #304 — the last, merged 2026-09-03 at 24082277); AC13 gates #278/#279, AC10/14/15 registration #283. LIVE ON DEV: /api/public/version reports develop-d4a6ab8a, drift=false (checked 2026-09-06). Outstanding: AC1/AC2 UAT boot-log verification, AC5 app.cron=true singleton + AC7 pool cap (two Portainer facts) — no code work left
reviewed_by: "independent adversarial lane 2026-09-02 — 5 claims disproven, recommendation changed D -> D-prime"
version: v2
ticket: SBDEV-3198
parent_ticket: SBDEV-3191
owner: Nam Park
created: 2026-09-02
updated: 2026-09-06
code_base: origin/develop @ d4a6ab8a (all 3198 work merged; 24082277 is the last 3198 merge)
related:
  - "[[SBDEV-3191-scheduling-boot-probe]]"
  - "[[wms2-scheduled-jobs-catalog]]"
---

# SBDEV-3198 — Per-tenant cron scheduling

**Status: IMPLEMENTED. All 6 of 6 jobs carry the Option D′ grouped shape on `develop`** —
`StaleClubBatchCleanupJob` (§7a step 3, PR #286 + follow-up #287), `StockSummaryExportJob` (step 4,
PR #288), `CleanUpOldMessagesJob` (step 5 part 1/4, PR #291 + activation-gate follow-up #296),
`ReleaseExpiredPickingOrdersFromUserJob` (part 2/4, PR #293), `OrderReleaseJob` (part 3/4, PR #301),
and `ReplenishOrderJob` (part 4/4, PR #304 — the last job, merged 2026-09-03 23:19 at `24082277`).
Plus AC13's authz work (PR #278, #279) and AC10/AC14/AC15's converging registration (PR #283).
**Live on dev**: `GET /api/public/version` returns `develop-d4a6ab8a` with `drift=false` (2026-09-06),
and `d4a6ab8a` is downstream of every 3198 merge. **No code work remains.** What is left is
environment verification only — AC1/AC2 from a UAT boot log, and the two Portainer facts behind
AC5/AC7. (the *which shape* question) is retained as-is for provenance; see §7a for current sequencing state.

> ### ⚠ Revision 2 — what independent review broke in revision 1
>
> Five claims were disproven. The pattern is worth recording: **every quantitative claim survived
> re-derivation** (the sysprop table, the caller counts, the blast radius to the digit, the group
> arithmetic, the `pg_proc` signatures); **every claim asserting a closed set, an impossibility or
> a completeness property broke or bent.**
>
> | Claim in rev 1 | Verdict |
> |---|---|
> | "at most ~1 `CronTrigger` lock-holder … the pool is sized to the stagger" (§2.3) | **BROKEN** — three second-0 crons already coincide at 03:00 today |
> | "migrating all eight locks would double-dispatch to OMS on every deploy" (§3.2) | **BROKEN** — `FOR UPDATE SKIP LOCKED` already prevents double-claim. Conclusion stands, reason does not |
> | "fatal for Option A" (§5.2) | **OVERSTATED**, and self-undermining — see §4's two-axis restructure |
> | "No new zone plumbing is needed" (§1.2) | **BROKEN** — both `TimezoneService` overloads throw without `TenantContext` |
> | "each environment is deployed by two webhooks" (§6) | **BROKEN for prd** — one webhook, and it is commented out |
> | `groupId` = "a stable hash of the tenant set **or** an assigned ordinal" (§4) | **UNSOUND, both variants** — the single most dangerous sentence in rev 1 |
>
> **The recommendation has changed from Option D to Option D′** (§4). Rev 1's Option D could not be
> implemented safely as specified.
>
> ### Blockers, as of 2026-09-02
>
> - ✅ **`app.cron=true` container count — ANSWERED: exactly one.** AC5 satisfied by design; no
>   deploy ceremony needed (§3.3).
> - ✅ **Pool caps — ANSWERED.** Per-tenant caps are in `tenant_db_configuration` (prd 5; uat
>   6/6/6/10). The landlord cap — the one that actually bounds the lock — is not in the DB but is
>   empirically ≫ 2 with large headroom, so AC7 is arithmetic, not a blocker (§2.3.1).
> - 🟡 **AC10, boot-time reachability — RECOMMENDATION MADE, awaiting a yes/no (§6a).** The root
>   cause is not the data dependency but the fact that **registration is one-shot**: no
>   `ScheduledFuture` is retained anywhere and nothing is ever cancelled. Recommendation is
>   **converging registration** — boot with whatever is reachable, reconcile on a fixed 5-minute
>   phase. It removes the dilemma rather than choosing a side, and it carries three constraints,
>   the first of which narrows the implementation: **AC14** (the reconcile must be a strict no-op
>   when nothing changed, or it drops up to 288 minutes of order release per day), **AC15** (its own
>   fixed phase at second 50), and the §6a.4 connect-bounding choice.

Parent: SBDEV-3191, which shipped Slice A (the boot probe) as PR #274 / `dbf795c1`, merged
`e663a9c3`. Slice A's provenance logging is what makes this ticket's AC1 verifiable from a boot log.

---

## 1. What is broken

### 1.1 One arbitrary tenant's schedule applies to every tenant (SBDEV-3191 §1)

`SchedulingConfiguration.configureAllTasks` builds **one** `CronTrigger` per job for the whole
process. Each `configureX` reads its `*_TIMER_HOUR` / `_MINUTE` through
`syspropService.getSysvalue(...)` under a single tenant's `TenantContext`, and `los_sysprop` lives
in the **tenant** database. So whichever tenant wins an arbitrary `ConcurrentHashMap` iteration
sets the schedule for all of them.

Measured 2026-09-02 against the four active UAT tenants — one deployment, one process:

| UAT tenant | `STOCK_SUMMARY_EXPORT_TIMER_HOUR` | `System Time Zone` |
|---|---|---|
| hydra/nywh | 3 | America/New_York |
| shipitez/nywh | 3 | America/New_York |
| shipitez/c1wh | 18 | America/Los_Angeles |
| wineco/wsl | 17 | America/Los_Angeles |

A 15-hour swing in when the nightly full-inventory export to OMS fires.

Two qualifications, both stated rather than implied:

- **Only `STOCK_SUMMARY_EXPORT_*` diverges today.** All four tenants agree on
  `CLEAN_UP_OLD_MESSAGES_TIMER_HOUR` = 2, `STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR` = 3, and
  `ORDER_TIMER_*` / `REPLENISHMENT_TIMER_*` = `*` / `*`. That is a coincidence of configuration,
  not a property of the code, so a fix still has to cover all six jobs.
- **Latent on dev and prd; live on UAT.** The config cache is `findByActiveTrue()`;
  `dev_landlord` has 1 active tenant of 4 and prd `wms2_landlord` has exactly 1. With one active
  tenant the arbitrary winner is the only tenant. §1 arms itself the moment a second tenant is
  onboarded to prd.

### 1.2 Firing zone hard-coded to Los Angeles (SBDEV-3191 §2)

`CRON_SCHEDULE_ZONE = TimeZone.getTimeZone("America/Los_Angeles")` applies to every `CronTrigger`.

Unlike §1 this is **live on production today with a single tenant**: Hydra's `System Time Zone` is
`America/New_York` and its export hour is 3, so the export fires at 03:00 LA = **06:00 New York** —
inside the morning shift rather than overnight.

`TimezoneService` already resolves a tenant's zone from the `"System Time Zone"` sysprop with a UTC
fallback and a WARN (`parseToZoneId`), and caches it by tenant key — so the **resolution logic is
reusable**.

⚠️ **But "no new zone plumbing is needed" was wrong** (rev 1). Both public overloads require
`TenantContext` and *throw* without it:

```java
public ZoneId getWarehouseZoneId() {
    TenantProfile p = TenantContext.getCurrentTenant();
    if (p == null || p.getFacilityCode() == null) {
        throw new IllegalStateException("... called without TenantContext ...");
```

and the overload that error message recommends, `getWarehouseZoneId(String facilityCode)`, *also*
requires `TenantContext`. There is **no `(tenantName, facilityCode)` form**. Trigger registration
runs on the boot-probe thread, whose `finally` clears `TenantContext` on every path. So resolving N
zones at registration needs either a new overload keyed on the tenant key, or a
`setCurrentTenant`/`clear` dance per tenant on the registration thread — which re-introduces the
stale-ThreadLocal hazard Slice A's own comment is about, on the same 10-thread pool that runs the
outbox dispatcher every 15s. **Budget for it.**

---

## 2. Three reasons the obvious fix is worse than doing nothing

"Register one `CronTrigger` per tenant" is the fix the parent ticket originally prescribed. On its
own it is a regression, for three *independent* reasons. The first two were found during Slice A's
triage; **the third is new in this document and is the most severe**, because it recurs every
minute rather than once per boot or per deploy.

### 2.1 N² tenant-executions

All six jobs **already** iterate every active tenant at fire time. Each `doCalculation(Boolean)`
opens with a loop over `tenantDbConfigurationRepository.findByActiveTrue()`, setting and clearing
`TenantContext` per tenant — verified by name in all six, not sampled: `CleanUpOldMessagesJob`,
`OrderReleaseJob`, `ReplenishOrderJob`, `StockSummaryExportJob`,
`ReleaseExpiredPickingOrdersFromUserJob`, `StaleClubBatchCleanupJob`.

Registration-time `TenantContext` is a ThreadLocal that is already cleared by the time a trigger
fires, so the arbitrary tenant only ever poisoned the **schedule read** — never which data got
processed. Add N triggers without touching those loops and each job runs N times a day, each run
processing all N tenants.

### 2.2 The advisory locks collide, and N−1 tenants skip silently

`AdvisoryLockService.JobLockId` holds one fixed constant per **job** — `ORDER_RELEASE = 100001L`
through `OUTBOX_DISPATCHER = 100008L` — and `AdvisoryLockService` pins them on
`@Qualifier("landlordDataSource")`, a single shared database, so there is one global lock namespace.

N per-tenant triggers for the same job fire at the same instant, contend on the same lock id, and
N−1 get `false` back and skip at **DEBUG**:
`"already running on another replica, skipping"`. Net effect: one arbitrary tenant processed instead
of all — strictly worse than today, and just as quiet.

### 2.3 ⚠ NEW — the landlord connection pool holds **two** connections, and each lock pins one

This is the finding that most constrains the design, and it is not on the ticket.

`AdvisoryLockService.tryLock` takes a raw connection and **pins it via ThreadLocal for the whole
duration of the job run**, because a PostgreSQL session-level advisory lock only exists on the
session that took it:

```java
Connection conn = landlordDataSource.getConnection();
... pg_try_advisory_lock(?) ...
if (acquired) { lockedConnection.set(conn); }
```

And the landlord pool is tiny:

```properties
landlord.datasource.maximum-pool-size=2      # application.properties
landlord.datasource.connection-timeout=20000
```

**Rev 1 claimed the pool is "sized to the stagger". That is BROKEN.** The 0/20/40 offsets separate
only the three *per-minute* jobs; `cleanUpOldMessages`, `stockSummaryExport` and
`staleClubBatchCleanup` all build **second-0** crons. On the measured UAT sysprops,
`staleClubBatchCleanup` (3/0) + `stockSummaryExport` (3/0) + `orderRelease` (`*`/`*`) + the outbox
tick **already coincide at 03:00:00 today** — four wanted connections against a nominal cap of 2.
So the coincidence this section warns about is not introduced by per-tenant triggers; it exists
now, which makes it *measurable* (see §2.3.1) rather than hypothetical.

The per-minute jobs are nonetheless offset by twenty seconds each:

| job | cron | fires at |
|---|---|---|
| `orderRelease` | `0 <min> <hour> * * *` → `0 * * * * *` | second **0** |
| `replenish` | `20 <min> <hour> * * *` → `20 * * * * *` | second **20** |
| `releaseExpiredPickingOrdersFromUser` | `40 * * * * *` (hard-coded) | second **40** |

…but that only covers those three. Second-0 collisions among the nightly jobs are unstaggered.

**Per-tenant triggers destroy the stagger.** All N tenants of a given job share the same cron
expression whenever their sysprops agree — which is exactly the case for `orderRelease` and
`replenish`, both `*` / `*` on all four UAT tenants. So N tasks fire at the *same second*, each
calling `landlordDataSource.getConnection()` and intending to hold it for the run. With
`maximum-pool-size=2`, two proceed; the rest block up to `connection-timeout=20000` (20s), then
Hikari throws `SQLTransientConnectionException`, which is a `SQLException`, which
`tryLock`'s outer catch turns into:

```java
LOG.error("Failed to acquire advisory lock {}", lockId, e);
return false;
```

→ **the job skips for those tenants, every minute, and the message blames the lock rather than the
pool.** At N = 4 that is 2 of 4 tenants' order release skipped per minute, continuously.

Any per-tenant design must therefore change one of: the landlord pool size, the per-trigger
stagger, or the number of simultaneous lock-holders. Section 4 picks the last.

#### 2.3.1 RESOLVED (2026-09-02) — two different pools, and only one of them matters here

⚠️ **First, a distinction rev 1 blurred.** There are **two** unrelated pool configurations, and
only the second bounds the advisory lock:

| | Configured by | Governs | Used by |
|---|---|---|---|
| **Tenant pools** (one per tenant) | `tenant_db_configuration.max_pool_size` in the landlord DB | connections to each *tenant* DB | the jobs' actual work |
| **Landlord pool** (one per JVM) | `landlord.datasource.maximum-pool-size` | connections to the *landlord* DB | `AdvisoryLockService` — `@Qualifier("landlordDataSource")` |

**AC7 is about the landlord pool**, because that is where `tryLock` pins its connection.

**Tenant caps — measured 2026-09-02** (`tenant_db_configuration`): prd hydra/nywh = **5**; uat
hydra/nywh **6**, shipitez/c1wh **6**, shipitez/nywh **6**, wineco/wsl **10**; `min_idle` 1 and
`connection_timeout_ms` 30000 on every row. Note the entity's field default is `= 2` and **no
landlord row uses it** — do not reason from the entity default. Under D′ a group's tenants are
processed serially, so the scheduler adds one connection at a time per tenant pool; 5–10 is ample.

**Landlord cap — still not readable from the DB, but empirically ≫ 2.** `maximum-pool-size=2` is
the in-repo value and is **not** the running value.
`sbdocs/3-Resources/reports/260901-wms2-multitenancy-readiness-audit.md` records that the arithmetic
does not reconcile: 1 api replica × a cap of 2 predicts 2 connections, but **prd shows 23
connections to `wms2_landlord`, 21 of them active within five minutes**. Either the cap is
overridden in the Portainer stack environment (where `app.cron` also lives — see §6), or something
outside `wms2-api` connects to the landlord database.

Measured directly on the prd landlord: **20 idle `PostgreSQL JDBC Driver` connections** (plus 2
unnamed and one psql session), **2** of which last ran an advisory-lock statement, and **zero
advisory locks held** at the time of sampling (no job mid-run). All arrive from a single
`172.18.0.1/32` Docker-bridge address, so containers cannot be distinguished by client address.

Since Hikari never exceeds `maximumPoolSize` and there is one landlord pool per JVM, 20 concurrent
connections against a claimed 2-per-JVM over ~2 containers is a **factor-of-five contradiction at
minimum** — the cap is overridden in the Portainer stack environment, as `app.cron` is. The exact
value is obtainable two ways, neither of them this repo: the Portainer stack env, or
`hikaricp_connections_max{pool="LandlordHikariPool"}` from the Prometheus actuator
(`management.endpoints.web.exposure.include` already includes `prometheus`).

⇒ **§2.3 is a real mechanism, is NOT urgent, and must NOT be a decision input.** With an aggregate
of ~20 landlord connections observed and today's peak requirement of ~2 simultaneous holders, the
headroom is large. Under D′ the requirement is bounded by *coincident groups* — a small number set
by configuration diversity — so AC7 becomes a stated arithmetic bound rather than a blocker.
Rev 1 used it as reason #2 for Option D; that is withdrawn. Every link in the mechanism is
confirmed — the connection is pinned until `unlock`'s `finally`, and Hikari's
`SQLTransientConnectionException` really does land in the `SQLException` catch and get misreported
as a lock failure — but the magnitude is unknown.

**It is cheaply settled, and for free.** Because three second-0 crons already coincide at 03:00
(§2.3), the condition is already being exercised nightly: **grep the cron replica's logs for
`Failed to acquire advisory lock` around 02:00, 02:55 and 03:00.** Absence over a few nights
settles it; presence makes §2.3 urgent on its own, independently of this ticket. Do that before
sizing AC7.

Do not resolve it by reading `application.properties` and concluding "the pool is 2" — that is the
same class of error as trusting a plan's `status:` field.

---

## 3. The lock-id mechanism — settled, with one hazard

A composite lock does **not** need a derived id space or a hash. PostgreSQL exposes a two-key
form, and it is present on our servers (checked against `pg_proc` on the prd landlord):

```
pg_try_advisory_lock(bigint)             <- in use today
pg_try_advisory_lock(integer, integer)   <- available, unused
pg_advisory_unlock(integer, integer)     <- available, unused
```

So `pg_try_advisory_lock(jobId, groupId)` is collision-free by construction.
`tenant_db_configuration.id` is comfortably int4-safe — prd `{2}`, uat `{3, 7, 13, 14}`.

### ⚠ 3.1 The one-key and two-key lock spaces are DISJOINT

`pg_try_advisory_lock(100001)` does **not** block `pg_try_advisory_lock(100001, 2)`. Proven from
`pg_locks` during review rather than argued from the docs: both rows carry the **same**
`(classid, objid)` and differ only in **`objsubid` — 1 for the two-key form, 2 for the one-key
form**. Same numbers, different lock identity, no contention.

That is fine steady-state and dangerous during a rollout: while some replicas still hold the old
single-key lock and others hold the new two-key lock, **mutual exclusion does not exist between
them** — duplicate order release, duplicate OMS export. Exactly what the locks are for.

### 3.2 The migration must not touch the two ungated jobs' locks — right conclusion, and rev 1 had the wrong reason

Investigated and now answered (§6). The deploy shape makes the disjoint-lock-space problem
**severe for two locks and benign for the other six**, and the difference is not intuitive:

- **`OutboxDispatcherJob` (`100008L`) and `RestIdempotencyCleanupJob` (`100007L`) are NOT
  `app.cron`-gated.** They are plain `@Service` + `@Scheduled` under the unconditional
  `@EnableScheduling` in `SchedulingEnablementConfig`, so they run in **every container** built from
  this image — the `wms-api` container *and* the separate `cron` container.
- **Dev and UAT** are deployed by **two independent, sequential Portainer webhooks** (`wms-api` and
  `cron`) with nothing sequencing or barriering them, so new-code api running alongside old-code
  cron is guaranteed on those deploys, for as long as one container's stop + pull + boot +
  per-tenant Flyway takes. Tens of seconds at minimum.
  ⚠️ **Not prd.** Rev 1 said "each environment", which is wrong and contradicted this document's own
  §6 sixty lines later: prd's deploy step is **commented out** in `docker-image.yml`, so prd is
  deployed by hand and its skew is whatever the operator does.
- `OutboxDispatcherJob` fires **every 15 seconds**. A skew of one boot cycle is many ticks.

⚠️ **Rev 1 concluded from this that a wholesale migration would "double-dispatch to OMS on every
deploy". That is BROKEN.** `OutboxMessageRepository.findAndClaimPending` claims rows with
`FOR UPDATE SKIP LOCKED` plus an atomic `PENDING`/`FAILED_RETRY` → `IN_FLIGHT` flip, so **two
dispatchers cannot claim the same row.** The advisory lock is a coarse efficiency guard on top of a
correctness mechanism that does not depend on it.

The real costs of losing that guard are narrower, and worth stating accurately because overstating
them is how a rule gets ignored once someone checks it:

- a **doubled OMS request rate** for the duration of the skew, and
- a narrow **Phase-0 re-send window** governed by `STALE_INFLIGHT_TIMEOUT` (5 min).

**The conclusion is unchanged and still right, but justify it correctly:** those two jobs want a
single process-wide lock, that is *correct for them*, and they are not in this ticket's scope.
"Do not change what you are not changing" is sufficient; the double-send argument is not needed and
is wrong.

**Therefore: add a two-key `tryLock(int, int)` / `unlock(int, int)` alongside the existing one-key
methods; do not migrate the existing ones.** The six `CronTrigger` jobs move to the two-key form;
`OutboxDispatcherJob` and `RestIdempotencyCleanupJob` keep the one-key form permanently, because a
single process-wide lock is *correct* for them — they iterate tenants internally and are not being
changed. The disjointness of the two spaces is then a **feature**: the six migrate without ever
contending against the two.

Write this as a comment on `AdvisoryLockService`, because "tidy up the remaining one-key call sites"
is an obvious and catastrophic future refactor.

**This is a specific instance of a rule the jobs catalog already states** — §2: *"Never reuse, never
change — a change is a silent breaker because replicas on old code will hold the old ID."* But the
rule as written had a **loophole this exact change walks through**: keeping the number `100008` and
switching to the two-argument form reads as "not changing the ID", while having precisely the same
effect, because the two lock spaces are disjoint. The catalog has been corrected to state the rule
as *never change the ID **or the lock form** — the (form, key) pair is the mutex identity.*

**Unchanged exposure worth noting so this design does not appear to alter it:** the catalog's §7
item 1 landmine is that session-level advisory locks break under PgBouncer transaction pooling. The
two-key form is still session-level, so this design neither worsens nor improves that. No PgBouncer
is deployed today.

### 3.3 RESOLVED — rollout risk for the six gated jobs is NIL. No cutover ceremony needed.

**Answered by Nam 2026-09-02: exactly one container carries `app.cron=true`.** That was the single
fact §3.3 was contingent on, and it closes the question:

- Deploys are **recreate**, so there is no self-overlap within a service.
- Only one container registers the six `CronTrigger` jobs, so no second holder of locks
  `100001L`–`100006L` exists at any time — including mid-deploy.

⇒ **The six gated jobs can migrate to the two-key form with no cutover, no dual-locking, and no
`app.cron=false` ceremony.** AC5 is satisfied by design rather than by procedure.

Two conditions under which this reverses, worth writing down because both are plausible roadmap
items: if `app.cron=true` is ever set on the 2–3-replica api tier (the audit records "1 today,
scaling to 2, max 3"), or if a second cron container is introduced, then §3.2's mixed-version
reasoning applies to all eight locks and a cutover becomes mandatory. **Guard it in the runbook,
not just here.**

### 3.3a Prior reasoning, retained — deploys are recreate, not rolling

Also answered in §6: a single service's redeploy is **stop-then-start**, evidenced by an observed
transient 502 during a forced webhook redeploy (recorded in
`sbdocs/1-Projects/wms2/plan/SBDEV-2967-A-axios-403-denial-not-logout.md`). No old container is left
serving, so there is **no self-overlap within a service**.

At today's shape — one container carrying `app.cron=true` — the six gated jobs are therefore **not
exposed** to the mixed-version window at all, and no cutover ceremony is needed for them.

That conclusion rests on one fact this repo cannot supply: **whether exactly one container has
`app.cron=true`.** `app.cron` is `false` everywhere in the repo and is injected out of band in the
Portainer stack environment. **Confirm it before implementing.** If the flag is ever set on a
2–3-replica api tier, §3.2's reasoning applies to all eight locks and a cutover becomes mandatory.

Mitigations if that check comes back badly, in preference order:

1. **Hard cutover with `app.cron=false`** — flag off, deploy both containers, flag on. No overlap,
   at the cost of a scheduling gap and a manual step. Cheapest to reason about.
2. **Two-phase deploy** — release *n* takes both the old and new lock; release *n+1* drops the old.
   Costs an extra pinned connection per holder during the transition, which §2.3/§2.3.1 says may not
   be available, so it must be paired with a pool increase.
3. **Accept the window** with the blast radius written down — defensible for the six given recreate
   semantics, never for `100008L`.

---

## 4. The candidate shapes — on TWO axes, not one

⚠️ **Rev 1 presented A/B/C/D as a single ladder and that was a structural error**, called out in
review: rev 1's Option D *is* Option B with a tenant **set** instead of a single tenant, so §4's
rejection of B ("the shape that rots") applied verbatim to D and was never charged against it. The
options actually vary on two independent axes:

| | **Axis 1 — entry-point shape** | **Axis 2 — trigger granularity** |
|---|---|---|
| | how a job is told which tenants to process | how many `CronTrigger`s exist per job |
| A | loop removed; job takes one tenant | one per tenant |
| B | loop kept; **second** entry point added | one per tenant |
| C | loop kept; filtered internally | one per tenant |
| D′ | loop kept; **one** entry point that accepts a scope | one per distinct firing specification |

The two-entry-point objection is an **Axis 1** cost, and D′ avoids it not by being a different
family but by making the *existing* `doCalculation` the degenerate case of the new one — a single
method with a widened parameter, not a parallel path. That distinction is what has to be true for
D′ to escape B's criticism, and it is a design constraint on the implementation, not a given.

---

## 4a. The candidate shapes

### Option A — per-tenant triggers, internal loops removed

One `CronTrigger` per (job × tenant); each job stripped to a single tenant. **This is the shape the
parent ticket originally prescribed.**

- ✅ Solves §1.1 and §1.2 completely.
- ❌ **Breaks the two non-scheduler callers (§5.2).** `AdminActionController` (5 jobs) and
  `StockCountRestController` (1) call `doCalculation(false)` meaning "all tenants, now". Removing the
  loop forces it to be re-implemented in both — three copies of the tenant loop, which is how §1.1
  arose.
- ❌ Trigger count 6N. At N = 4 that is 24 triggers, and 12 tasks in the same minute against
  `POOL_SIZE = 10` — scheduler-pool starvation on top of §2.3's connection starvation.
- ❌ Largest test blast radius: **19 coupled files / 164 `@Test`** (§5.3), most of which must be
  revisited because the entry point changes meaning.
- ❌ Requires the pool and stagger work from §2.3 regardless.

### Option B — per-tenant triggers, loops kept, new per-tenant entry point

Adds a second entry point per job alongside `doCalculation`.

- ✅ Smaller diff than A.
- ❌ Two execution paths per job, permanently. This is the shape that rots: the multi-tenant path
  stays reachable and untested, and a future edit to one path silently diverges from the other.
- ❌ Same trigger-count and pool problems as A.

### Option C — per-tenant triggers, job filters its own loop to one tenant

- ✅ Smallest diff.
- ❌ Keeps the loop as dead weight and is the easiest of all to regress back into N².
- ❌ Same trigger-count and pool problems.

### Option D (rev 1, superseded) / **D′ — ⭐ group by firing specification, lock per tenant (RECOMMENDED)**

Register one `CronTrigger` per **distinct `(cronExpression, zoneId)`** rather than per tenant, and
hand each trigger the *set* of tenants that share that specification. The job processes that subset.

This works because the defect is not "triggers are not per-tenant" — it is **"tenants with
different schedules are forced onto one schedule."** Grouping by the schedule addresses the defect
directly, and tenants that genuinely share a schedule have no reason to be separated.

Measured on the four active UAT tenants:

| job | tenants | distinct `(cron, zone)` groups |
|---|---|---|
| `stockSummaryExport` | 4 | **3** — (3, NY) → hydra+shipitez/nywh; (18, LA); (17, LA) |
| `orderRelease` | 4 | **2** — (`0 * * * * *`, NY); (`0 * * * * *`, LA) |
| `cleanUpOldMessages`, `staleClubBatchCleanup` | 4 | **2** (hours agree; zones differ) |
| `releaseExpiredPickingOrdersFromUser` | 4 | **1** — cron is hard-coded, no timer sysprop exists |

Why this is the better shape:

- ✅ **Solves §1.1 and §1.2 exactly.** Every tenant fires on its own hour/minute in its own zone.
- ✅ **Concurrency is bounded by distinct schedules, not tenant count** — which is what makes
  §2.3 tractable. Growth is bounded by *configuration diversity*, not by onboarding: a fifth tenant
  that shares an existing schedule adds no trigger and no lock-holder.
- ✅ **One new entry point per job**, taking the tenant subset; the existing `doCalculation`
  becomes the degenerate "all active tenants" case rather than a second permanent path.
- ✅ The internal loop **stays and stays used**, just over a supplied subset — so the six jobs'
  metrics, error isolation and per-tenant `TenantContext` handling are untouched.
### 🚨 The three things rev 1 got wrong about D, and what D′ does instead

**1. The lock key must NOT be derived from group membership.** Rev 1 said *"`groupId` is a stable
hash of the sorted tenant-key set **or** an assigned ordinal"*. Review called this the single most
dangerous sentence in the document, and both variants fail, in opposite directions:

- **A membership hash is content-addressed on a set that changes** on onboarding, deactivation, *or
  a timer-sysprop edit*. Two JVMs that grouped at different times compute **different keys for
  overlapping work**: container X's `(0 0 3, NY)` group is `{hydra, shipitez/nywh}` → `H1`;
  container Y, booted after a sysprop edit, gets `{hydra}` → `H2`. Both fire at 03:00, both
  acquire — **hydra is exported twice, concurrently.** Mutual exclusion is lost under *config*
  skew, not just code skew, so §3.3's recreate-semantics argument does not save it.
- **An ordinal is worse.** Ordinals shift when a new schedule appears, so X's `groupId = 2` and
  Y's `groupId = 2` denote *different tenant sets*: they contend on the same key, one wins, and the
  loser's tenants are **not processed at all** — §2.2's silent skip, reintroduced by the fix.

✅ **D′ locks on `(jobId, tenant_db_configuration.id)`** — the unit of work, not the grouping.
It is a landlord primary key, never re-derived, int4-safe (prd `{2}`, uat `{3,7,13,14}`). Mutual
exclusion becomes **grouping-independent**: two replicas that disagree about grouping still contend
on the same per-tenant key, so no skew can disarm it. It is also the *correct* invariant — "one
replica processes tenant X's order release" is what is actually wanted; "one replica runs
orderRelease" was always a coarser proxy. `groupId` disappears from the lock entirely and stays a
pure scheduling concept. Bonus: the admin "run now" path then skips only a tenant the scheduler is
mid-processing, instead of skipping the whole job.

**2. Triggers must carry the SPECIFICATION, not a frozen tenant set.** Rev 1 said *"hand each
trigger the set of tenants that share that specification"* and *"groups are computed at boot"*.
That moves tenant enumeration from **fire time** to **boot time**, which is a silent regression in
both directions:

- a tenant **activated** after boot gets no trigger at all for the life of the process (today its
  next tick picks it up), and
- a tenant **deactivated** after boot keeps being processed against a frozen set (today the
  fire-time `findByActiveTrue()` drops it immediately) — writing to a tenant someone switched off.

Rev 1's "honest cost" admitted only *schedule* staleness, which genuinely is not a regression.
**Membership staleness is a different thing and it is one.**

✅ **D′ hands each trigger its `(cronExpression, resolvedZoneId)` spec** and the job re-derives
members at fire time from `findByActiveTrue()` plus each tenant's timer sysprops, keeping those
matching the spec. Activation and deactivation stay live. Cost is near-zero — the jobs already
open each tenant's context and read `NEW_CRON_JOB_ACTIVATED` + `*_TIMER_ACTIVATED` per tenant per
tick, so two more cached sysprop reads are marginal.

**3. Zone-invariant crons must collapse.** Rev 1's own table listed `orderRelease` → 2 groups,
`(0 * * * * *, NY)` and `(0 * * * * *, LA)`. But **`0 * * * * *` is zone-invariant** — a per-minute
cron fires at identical instants in every zone. Rev 1 therefore *manufactured* a second coincident
trigger and a second simultaneous lock-holder for **zero** correctness gain, in the job that fires
most often, against the very pool pressure §2.3 raises. At today's UAT config rev 1's D gives **5
per-minute triggers where today there are 3**.

✅ **D′ collapses any cron whose day-and-below fields are all wildcards into a single group**,
restoring 3.

### Remaining honest costs of D′

- ⚠ **Groups can still coincide in time.** `(0 0 3, NY)` and `(0 * * * * *, NY)` both fire at 03:00,
  so simultaneous holders remain possible — but under the per-tenant lock they no longer *contend*
  wrongly, and the pool arithmetic (§2.3.1) is bounded by coincident groups, not by N.
- ⚠ **AC1/AC2 are vacuous for one job.** `releaseExpiredPickingOrdersFromUser` hard-codes
  `"40 * * * * *"` and there is no `*_EXPIRED_*` timer constant in `WmsConstants` at all, so it
  cannot fire on a tenant's sysprops and its zone is irrelevant (per-minute ⇒ zone-invariant).
  AC1/AC2 must be scoped to **the five jobs that read a timer sysprop**.
- ⚠ **The UTC fallback creates a silent third schedule.** `parseToZoneId` returns UTC with a WARN
  for a null/blank/invalid zone sysprop, so such a tenant lands in a `(cron, UTC)` group. The
  grouping key must be the **resolved** `ZoneId`, and the fallback must be logged **per tenant at
  registration** — in the provenance line Slice A added — or a tenant's export moves by hours with
  the only warning buried at boot.
- ⚠ **A malformed cron field costs a whole group.** `configureX` rejects only null/blank
  hours/minutes; anything else is concatenated and handed to `CronTrigger`, which throws. Today
  that costs one job; under D′ it must cost one *group*, with the surviving groups still
  registering.
- ⚠ **Post-boot sysprop edits now create a new kind of disagreement**: the tenant stays in a group
  whose cron no longer matches its own sysprop, so the boot provenance line and the DB diverge.
  Worth a catalog note.

### Recommendation

**Option D′** — grouping by firing specification, **locking per tenant**, specs not frozen sets,
zone-invariant crons collapsed. Two reasons, and note that rev 1's second reason is **withdrawn**:

1. **§5.2 — `doCalculation` has three production callers.** A/B/C push the tenant loop into
   `AdminActionController` and `StockCountRestController`, or those "run now" paths degrade to one
   arbitrary tenant. D′ leaves both untouched. This is the strongest reason and it survived review
   as a *cost* argument, though not as the word "fatal" (§5.2).
2. **§5.3 — the `doCalculation` contract is preserved**, so the bulk of the existing test surface
   stays meaningful and the new work is additive rather than migratory.
3. ~~**§2.3 — concurrency must not scale with tenant count.**~~ **WITHDRAWN.** The mechanism is
   real but its magnitude is unknown and probably small: prd runs ~20 concurrent landlord
   connections, so the effective cap is ≫ 2 (§2.3.1). It is no longer a decision input. It remains a
   thing to *measure* (grep for `Failed to acquire advisory lock` at 02:00/02:55/03:00) and to bound
   in AC7, not a reason to prefer a shape.

**No cutover ceremony**, provided the `app.cron=true` container count is confirmed to be one
(§3.3) — deploys are recreate, so the six gated jobs are not exposed to the mixed-version window.

**Honest costs of D′**, all in §4a: AC1/AC2 are vacuous for one of the six jobs; the UTC fallback
creates a silent third schedule unless logged per tenant at registration; a malformed cron field
must cost one group rather than the job; post-boot sysprop edits make the provenance line and the DB
disagree in a new way; and D′ still has to answer §6b's boot-reachability question below.

**What would change my recommendation:** if the `app.cron=true` container count turns out to be
greater than one, §3.3's "no cutover needed" collapses and the deploy sequencing becomes the
dominant cost — at which point the smaller-diff options deserve a second look purely to shrink the
window.

---

## 5. Blast radius

### 5.1 ⚠ `JobMetrics` — five whole-run metrics change meaning under EVERY option, D included

Verified by reading `JobMetrics.java` and the call sites, not inferred. `JobMetrics` splits cleanly
into two families:

- **Per-tenant, tagged** — `tenantSuccess(String tenant)`, `tenantFailure(tenant, reason)`,
  `tenantSkippedNotActivated(tenant)`, `rowsProcessed(tenant, n)`,
  `stopTenantTimer(sample, tenant)`, and the `OrderReleaseJob`-only
  `tenantOrdersSkippedNoSection` / `tenantOrdersMarkedNoSection`. **These are safe** — they are
  emitted inside the loop and stay correct however the loop is driven.
- **Whole-run, untagged** — `markLastSuccess()`, `markLastRun()`, `recordDuration(long nanos)`,
  `skippedLockBusy()`, `skippedJvmBusy()`. **These five are the problem**, and each breaks in its
  own way: the first two are gauges whose last writer wins; `recordDuration` is a whole-tick timer
  that silently becomes a per-tenant timer under the same metric name; and the two `skipped*`
  counters **inflate by N−1 per tick** once there are N groups rather than one run.
  `shutdownDrainTimeout()` is also untagged but fires on shutdown rather than per run, so its
  meaning does not change — 5 of 16 methods, not 6.

  Note `rowsProcessed(tenant, n)` sits in the tagged family but has **zero `src/main` call sites**.
  It is dead code; do not spend effort preserving it.

The mechanism, at `OrderReleaseJob`:

```java
boolean anyFailure = false;
for (TenantProfile tenantProfile : tenantProfiles) { ... anyFailure = true; ... }
if (!anyFailure) jobMetrics.markLastSuccess();
```

`StockSummaryExportJob` has the identical shape. So **today `markLastSuccess()` means "every active
tenant succeeded"** — a fleet-health signal.

Split the run across G triggers and it does not merely narrow to "this group succeeded". Because
`markLastSuccess` / `markLastRun` are **gauges**, not counters, the last writer wins: the gauge
becomes *"the most recently finishing group's outcome"*, which is non-deterministic across groups
and strictly less meaningful than either reading. Any alert of the form
`time() - wms2_cron_order_release_last_success_epoch_seconds > threshold` silently changes meaning —
it would go green whenever *any* group succeeds, masking a tenant that has been failing for days.

`skippedLockBusy()` has the same defect in a different direction: with per-group locks it fires
without recording *which* group was skipped, so §2.2's regression would be invisible in metrics as
well as in logs.

#### ✅ 5.1.1 The existing metric tests CANNOT see this regression — pin WRITTEN (PR 1)

**Status: done.** `WholeRunSuccessGaugeUnitTest` (20 tests, 4 × 5 jobs) landed as this ticket's
first PR — test-only, no production change, all 20 passing against unmodified `develop`, which is
what makes it a regression pin rather than an assertion written to match the refactor.

The gap was real but its cause was **not** what the first pass of this document said. Corrected by
two review lanes:

- The five `*MetricsUnitTest` files **retain** the registry but use a **single-tenant** fixture,
  where "every tenant succeeded" and "this tenant succeeded" are indistinguishable.
- The five `*JobTest` files **already had** two-tenant, one-fails fixtures — including
  `ReplenishOrderJobTest.shouldHandleExceptionAndContinueProcessingOtherTenants` and
  `StockSummaryExportJobTest.shouldProcessRemainingTenantsWhenOneTenantFails` — but each passes
  `new JobMetrics(new SimpleMeterRegistry(), …)` inline and **never keeps a reference**, so no metric
  assertion is possible in the file where the discriminating fixture lives.

So both halves of the pin already existed, in different files, and neither half alone could observe
the gauge. The earlier claim that `StockSummaryExportJob` "has no happy-path test at all" was wrong.

**The ordering that matters — do not lose this.** A failure injected on the *last* tenant does NOT
discriminate: a per-iteration failure flag, or a per-tenant invocation marking the gauge at the end
of its own body, leaves the flag `true` at loop end and stays green. Only injecting the failure on
the **first** tenant puts a success write *after* a failure, which is the actual hazard. Verified by
hand: moving `boolean anyFailure = false` inside the loop in `CleanUpOldMessagesJob` fails
`firstTenantFails` and **only** that test — 1 of 4 red. PIT cannot generate that mutant, so it would
have shipped unnoticed.

Also corrected: it is **five of the six** `app.cron`-gated jobs, not all of them. The sixth,
`StaleClubBatchCleanupJob`, runs the same whole-fleet loop with **no `JobMetrics` at all**, so it has
no freshness gauge to pin — a larger gap than this one, and still open.

Mutation-checked with PIT scoped to the five job classes: every mutant it generates on
`markLastSuccess` or its `!anyFailure` guard is killed, 15/15, each by the intended test.

**Two findings the pin surfaced, both still open:**

1. **The `isEmpty()` early return marks success without running anything** — so a freshness alert
   cannot distinguish "all tenants healthy" from "no tenants configured". PIT reported all five of
   these call sites as unkilled. Now pinned as *characterization, explicitly not as desirable*, so
   AC10's reconcile loop — which may legitimately register zero triggers — has to decide this in
   review rather than by accident.
2. **The admin console writes the same untagged gauge.** Because `isCronJob` is declared and never
   read in four of the five jobs (§5.1a), `AdminActionController`'s `doCalculation(false)` runs the
   whole-fleet loop and refreshes the fleet freshness signal. An operator pressing "run now" can
   green a stale-data alert. Live today; unpinned.

**What a reviewer of the refactor must reject.** These tests drive `doCalculation(true)`, which this
ticket changes — so the class may stop *compiling* rather than failing, and a compile error invites
deletion. It must not be resolved that way. The invariant to preserve, per job: **no per-tenant or
per-group invocation may write the untagged whole-run gauge.** If per-group freshness is needed, that
is a new tagged meter plus a coordinated dashboard/alert change, not a redefinition of this one.

Also confirmed while checking: `rowsProcessed(tenant, n)` has **zero `src/main` call sites** — dead
code in the metrics surface, not something to preserve.

**This makes AC6 load-bearing rather than housekeeping.** The minimum correct change is to tag the
whole-run family by group (or tenant), which is a metric-name/cardinality change and therefore a
dashboard-and-alert change outside this repo. That needs to be sequenced with whoever owns the
Prometheus alerts. It is the single most likely thing to be forgotten.

Also note `StaleClubBatchCleanupJob` uses `JobMetrics` **not at all** (zero call sites) — a
pre-existing parity gap already recorded in the scheduled-jobs catalog, not introduced here, but it
means one of the six jobs has no metric coverage to preserve or to break.

### 5.1a ✅ CLOSED — `isCronJob` WAS a dead parameter in four of the six jobs (fixed by AC13(b), `3849a223`)

**Status 2026-09-02:** the four dead-parameter jobs were fixed by AC13(b) (PR #279 `3849a223`);
they now resolve `TenantContext.getCurrentTenant()` and refuse when it is absent. The table below
is the **pre-fix** state, retained because it is the evidence for AC13 and for the invariant in
§5.2a. ⚠ One row of it was **wrong**, and the only surviving instance of the defect hides in
that row — see the correction under the table.

Verified by counting occurrences of `isCronJob` in each job (a count of 1 means it appears only in
the signature):

| Job | `isCronJob` | Behaviour when called with `false` |
|---|---|---|
| `StockSummaryExportJob` | **used** — `if (isCronJob) { loop } else { exportStockSummary(null); }` | single tenant (the caller's, via request-scoped `TenantContext`) |
| `StaleClubBatchCleanupJob` | **used — but NOT for scoping** | ⚠ **loops ALL tenants** — see correction below |
| `CleanUpOldMessagesJob` | signature only | **looped ALL tenants** — ✅ fixed `3849a223` |
| `OrderReleaseJob` | signature only | **looped ALL tenants** — ✅ fixed `3849a223` |
| `ReplenishOrderJob` | signature only | **looped ALL tenants** — ✅ fixed `3849a223` |
| `ReleaseExpiredPickingOrdersFromUserJob` | signature only | **looped ALL tenants** — ✅ fixed `3849a223` |

⚠ **CORRECTION 2026-09-02 — the `StaleClubBatchCleanupJob` row above read "used / honours the
flag". It does not honour it, and that job is now the WORST of the six.** An `isCronJob`
occurrence count cannot tell you *what the flag guards*, which is exactly how the wrong row
survived into an acceptance criterion. Re-verified at `origin/develop`: `findByActiveTrue()` is
called **unconditionally** — grep `"tenantDbConfigurationRepository.findByActiveTrue()"` in
`StaleClubBatchCleanupJob.java`, it sits above any flag check — and `isCronJob` is read only
**inside** the per-tenant loop, where it skips the sysprop activation check, never the tenant
scope. So it fans out across every tenant on a `false` call, *and* it was left out of AC13(b)'s
fix. It is latent **solely** because nothing calls it with `false` today; the first non-scheduled
caller makes it live. Fix the scoping in the same change that gives it one.

Two consequences, both material:

1. **`StockSummaryExportJob` already has the target shape.** One of the six is half-converted
   already, and three of its test files already drive the single-tenant branch. It is the proof that
   the shape works in this codebase — but see the sequencing note below for why it is not the right
   job to convert first.
2. ✅ **FIXED `3849a223` — was a LIVE cross-tenant defect in the admin console.**
   `AdminActionController` passes `false` to five jobs intending "this operator's action", and
   four of them ignored it. So a Hydra operator pressing "run order release now" triggered order
   release for **shipitez and wineco too**. That was live on `develop` until `3849a223`,
   independent of this ticket. It is in scope *here* rather than a separate
   ticket because SBDEV-3198's whole job is to decide what per-tenant invocation means — deciding
   `isCronJob`'s contract is unavoidable. Whatever shape is chosen must state explicitly what the
   five admin triggers do afterwards, because **tenant-scoping the invocation changes behaviour on
   shipped endpoints** either way.

### 5.2 `doCalculation` has THREE production callers, not one

The most important structural fact in this document, and it is not on the ticket. Derived from
`git grep -n 'doCalculation' origin/develop -- src/main`:

| Caller | Jobs invoked | Argument | Intent |
|---|---|---|---|
| `SchedulingConfiguration` | all **6** | `doCalculation(true)` | scheduled run |
| `AdminActionController` | **5** — order release, replenish, stock summary export, clean-up messages, release-expired-picking | `doCalculation(false)` | operator pressing "run now" in the admin console |
| `StockCountRestController` | **1** — stock summary export | `doCalculation(false)` | REST-triggered export |

The two non-scheduler callers **legitimately mean "run for every active tenant, now"**. That is not
an accident of the current design; it is what an operator pressing "run now" wants.

⚠️ **Rev 1 called this "fatal for Option A". That is OVERSTATED** — review pointed out that a
five-line `doCalculation()` wrapper keeps one copy of the loop and leaves both controllers
untouched. It is a **real cost**, not a blocker: stripping the loop forces either that wrapper or a
re-implementation in `AdminActionController` and `StockCountRestController`, and three copies of the
tenant loop is the shape that produced §1.1. But A survives it.

⚠️ **And rev 1's premise — that "run now" *means* all tenants — was asserted with no evidence, and
the code argues the other way.** See §5.2a. So this section is a cost comparison, not a
correctness argument.

**Option D is free here.** `doCalculation(Boolean)` keeps its existing "all active tenants"
semantics for the admin and REST callers, untouched and untested-against; the new group-scoped entry
point is called *only* by `SchedulingConfiguration`. The internal loop stays, stays used by all
three callers, and simply iterates a supplied subset when the scheduler supplies one.

### 5.2a ⚠ The "run now means all tenants" premise is unevidenced — and two of these endpoints are UNGATED

Verified in `AdminActionController`:

Complete enumeration of `AdminActionController` (`/v3/adminAction`, which has **no class-level
gate** — it extends `AdminController`), every endpoint that invokes a job:

| Endpoint | Authz | Job(s) invoked | Honours `isCronJob`? | Effective scope |
|---|---|---|---|---|
| `triggerOrderReplenish` | `@RequiresFunction(WEB_UI_VIEW_IMPORT_DATA)` | **two** — `orderReleaseJob` *and* `replenishJob` | no (dead param) | **all tenants** |
| `triggerArchiveMessages` | `@RequiresFunction(WEB_UI_VIEW_IMPORT_DATA)` | `cleanUpOldMessagesJob` | no (dead param) | **all tenants** |
| `triggerUpdateStock` | 🚨 **NONE** — no `@RequiresFunction`, no `@PreAuthorize` | `stockSummaryExportJob` | yes | caller's tenant |
| `triggerReleaseExpiredPickingOrdersFromUser` | ✅ `@RequiresFunction(WEB_UI_VIEW_IMPORT_DATA)` — **AC13, 2026-09-02** | `releaseExpiredPickingOrdersFromUserJob` | no (dead param) | 🚨 **all tenants** |

(The controller's other five endpoints — `testCrmConnectivity`, `finishStuckPickingOrder`,
`listRecoverableStuckPallets`, `recoverStuckPallets`, `accessAudit` — are all gated and invoke no
jobs. So this is 2 ungated of 4 job-triggering endpoints, not 2 of 9.)

`StockCountRestController.triggerStockCount` (`/rest/stockcount`) also calls
`stockSummaryExportJob.doCalculation(false)` with no gate, but `/rest/**` is the internal WMS↔OMS
surface where JWT is deliberately deferred — **not** a live exposure, and out of scope here.

Two distinct problems, and only one of them is about scoping:

1. ~~**`triggerReleaseExpiredPickingOrdersFromUser` is ungated**~~ **AND fans out across every
   tenant.** Was worst of the four. **Authorization closed by AC13(a) (2026-09-02, `a33a59ac`)** — one annotation,
   the console's own entitlement, no new constant; measured beforehand on dev, where a
   non-super-admin `wms_user` reached it at HTTP 200. ⚠ ✅ **The fan-out half is now closed too (AC13(b), `3849a223`)**:
   `doCalculation` resolves the caller's tenant and refuses when there is none, so this
   single-tenant entitlement now authorizes exactly one tenant's writes. It was treated as an
   **invariant rather than an instance**, which is why the same fix landed on
   `triggerOrderReplenish` and `triggerArchiveMessages` in the same PR (item 2 below) rather than
   on the reported endpoint alone — as an instance pin it would have closed one of four and read
   as done.
2. ✅ **FIXED `3849a223` — the two *gated* endpoints used to gate on a per-tenant function while
   fanning out across all tenants**: a Hydra user holding `WEB_UI_VIEW_IMPORT_DATA` caused order
   release, replenishment and message archival to run for shipitez and wineco. `doCalculation`
   also cleared the request thread's `TenantContext` on the way out; it now restores the caller's
   tenant in the inner `finally`.

Pre-existing; not introduced by this ticket. But it **destroys rev 1's premise** that the
all-tenant behaviour is *intended* — it is far more likely an accident of the dead `isCronJob`
parameter (§5.1a).

✅ **IN SCOPE for this ticket (Nam, 2026-09-02).** Folded in rather than filed separately, because
this ticket has to settle `isCronJob`'s contract anyway and cannot decide invocation scope without
deciding what these endpoints do. See **AC13**.

### 5.3 Test blast radius — measured

Derived by enumerating every `src/test` file referencing any of the six job classes, then
classifying by whether it calls `doCalculation` and whether it stubs `findByActiveTrue()` (the
latter being structural coupling to the loop's existence):

**Two instruments were run. They do not disagree — they answer different questions, and both were
independently reproduced.** A file-level pass (**30 files; 19 coupled; 164 `@Test` in those 19; 5
files / 22 `@Test` calling `doCalculation` without stubbing the loop; 6 neither**) was re-derived to
the digit by a second reviewer. A per-test pass with a brace-balanced parser measured individual
tests. Use the file-level figures to scope *which files to open*, and the per-test figures to scope
*how many edits*:

| Measure | All | Live (excl. `@Disabled`) |
|---|---|---|
| `@Test` methods across the 30 files | **242** | 236 |
| …that call `doCalculation` | **141** | 135 |
| …that stub `findByActiveTrue()` | **116** | 110 |
| Service/repository tests below the loop, unaffected | 28 | 28 |

Per-job `doCalculation` call totals: Replenish **50**, OrderRelease **28**, StockSummaryExport
**20**, CleanUp **17**, ReleaseExpired **17**, StaleClub **2**.

**The rework is far more leveraged than the raw count suggests.** `ReplenishOrderJobTest`'s 42 tests
sit behind **one** helper, `setupActivatedJob()`, with 35 call sites; two `@BeforeEach` edits cover
nine more. So the 141 is not 141 individual edits.

Also: **6 tests are `@Disabled`** under a `@Nested class DoCalculation` (an SBDEV-2099 environment
skip), and two of those files are entirely dead — worth deleting or re-enabling rather than
migrating.

**Under Option D that 164 shrinks substantially** rather than being paid in full: the existing
`doCalculation()` contract is preserved, so tests that stub `findByActiveTrue()` and assert
all-tenant behaviour keep passing unchanged. The new work is additive — tests for the grouping
logic and the group-scoped entry point. Under A/B/C most of the 164 must be revisited because the
entry point they exercise either changes signature or changes meaning.

Blind spot in this count: it matches on class-name references, so a test that exercises a job purely
through a service seam without naming the class is not counted. Two such were seen
(`ReplenishOrderJobServiceUnitTest`, `StaleClubBatchCleanupJobServiceUnitTest`) and are in the
"neither" bucket — they test extracted services and are unaffected either way.

Scale of the production classes, for context: the six jobs are 77–521 lines
(`ReplenishOrderJob` largest, `StaleClubBatchCleanupJob` smallest), each with exactly one
`findByActiveTrue()` loop and exactly one `tryLock` call site.

---

## 6. Deployment topology — ANSWERED

Investigated 2026-09-02. The topology is **not in this repo** — it lives in Portainer — but enough
is derivable from the workflows plus prior vault records to settle §3.

| Question | Answer | Evidence |
|---|---|---|
| Where is `app.cron=true` set? | **Nowhere in the repo.** `application.properties` has `app.cron=false`; every `true` is in `docs/` prose or `src/test`. No per-environment property files exist (only `src/main` + two `src/test`). No `APP_CRON` env override in any `Dockerfile` or workflow. ⇒ injected out of band in the Portainer stack env, **per container**. | exhaustive `git grep 'app\.cron'` + `git ls-tree` for `application-*` |
| Replicas? | **Not declared in the repo** — no `replicas:`, no compose/k8s/helm, zero rows for `compose|stack|portainer|swarm`. Already answered by a human: **1 api replica today, scaling to 2, max 3.** | `260901-wms2-multitenancy-readiness-audit.md` |
| Containers per environment? | **Two** — `wms-api` and a separate `cron` service, both from the same image, each with its **own** Portainer webhook. So JVMs running this image ≥ 2 today, up to 4 at the 3-replica ceiling. | `docker-image-develop.yml` fires two webhook POSTs, steps named "wms-api and cron service"; independently concluded in `reviews/PR174-cross-tenant-cache-key-review-impact.md` |
| Rolling or recreate? | **Recreate (stop-then-start).** A forced webhook redeploy was **observed as a transient 502**, i.e. no old container left serving. No `strategy:`/`RollingUpdate`/`update_config` anywhere to contradict it. | `SBDEV-2967-A-axios-403-denial-not-logout.md` |
| So where is the real overlap? | **Between the two services, not within one.** The two webhooks are two sequential `curl` calls to different endpoints with nothing sequencing them, so new-code `wms-api` runs alongside old-code `cron` for one container's stop + pull + boot + Flyway. | same workflow file |

`.gitlab-ci.yml` is **vestigial** for this purpose: tag-gated, stages `build`/`image` only, script
ends at `docker push` with a comment about deploying "in kubernetes", and there are no k8s manifests.
It performs no deploy. Prod's deploy webhook is **commented out** in `docker-image.yml`, so prod is
deployed by hand.

Two traps to carry into implementation:

- **A green deploy pipeline is not evidence of a deployed build.** A recorded run had a green
  pipeline, both webhooks 2xx, and the container never picked up the new `:develop` image. Confirm
  with `GET /api/public/version`.
- **"1 replica" is asserted, not instrumented**, and a landlord connection count is currently not a
  usable instrument for confirming it — see §2.3.1's 23-connection discrepancy.

### 6.1 Startup timing — narrows the six, does nothing for the two

*Reasoning, not measurement.* A newly started container registers no `CronTrigger` for at least
~5 seconds (`ApplicationReadyEvent` + a deliberate 5s defer) and may probe tenant DBs for up to 60
attempts before registering anything, so it holds none of the six locks during that window. That
narrows an api↔cron skew for the gated six. It does **nothing** for `100007L`/`100008L`, whose jobs
are `@Scheduled` and start firing as soon as Spring's scheduler is up — which is exactly why §3.2 is
the hazard that matters.

---

## 6a. ✅ AC10 — the converging-registration decision (DECIDED 2026-09-02), and the four constraints it carries

**Recommended answer to AC10: make registration CONVERGING rather than one-shot.** This section
states why, and the three constraints that fall out of it — the first of which materially narrows
the implementation and was surfaced by asking what happens to the every-minute jobs.

### 6a.1 The real problem is one-shot registration, not the data dependency

Verified at `origin/develop`: **all seven `scheduler.schedule(...)` return values are discarded, no
`ScheduledFuture` is retained anywhere, and there is no cancel or re-register path** in
`schedulejob/` or `landlord/config/`. Registration happens exactly once, at boot.

Today that is tolerable: one trigger per job is created from one tenant's sysprops — wrong, but
*present*. Under D′ the **number of triggers and when they fire** is a function of the whole tenant
set, so two unreachable tenants at boot do not produce a slightly-wrong schedule; they produce **no
trigger at all for those tenants, for the life of the process.**

Both answers originally offered are downstream of the same root cause and both are bad:

| Option | Why it fails |
|---|---|
| Block until all N tenants are reachable | Re-arms the unbounded hang Slice A was written to remove; one down tenant stops scheduling for everyone |
| Register partial groups, frozen at boot | §1.1's "one arbitrary tenant's schedule" defect in a new costume, now silent for the process lifetime |

**Converging registration removes the dilemma** instead of choosing a side of it, and it pays for
itself three ways: AC11 (activation/deactivation liveness) becomes true by construction; a timer
sysprop edit takes effect within the refresh interval instead of requiring a container restart
(**better than today**, where nothing re-reads it); and a tenant down at boot self-heals instead of
waiting for a deploy.

### 6a.2 🚨 CONSTRAINT 1 — the reconcile must be a no-op when nothing changed

**This is the most important constraint in Slice B and it exists because of the every-minute jobs.**

`orderRelease` and `replenish` are the highest-frequency and most business-critical jobs, and on
**prd** both are `*` / `*` (`ORDER_TIMER_HOUR`, `ORDER_TIMER_MINUTE`, `REPLENISHMENT_TIMER_HOUR`,
`REPLENISHMENT_TIMER_MINUTE` all `*`, measured 2026-09-02) — i.e. genuinely once per minute.

A reconcile that cancels and re-adds a trigger each cycle would drop ticks: between `cancel()` and
`schedule()` a second-0 boundary can pass, and **that minute's order release never runs**. At a
5-minute cadence that is up to **288 lost minutes of order release per day**, on the job that can
least afford it, and it would look like an order-flow problem rather than a scheduling one.

⇒ **The reconcile must be a true diff, strictly no-op when the desired trigger set is unchanged,
and per-trigger granular. Never "cancel all and re-register."** A schedule change legitimately
costs one tick; an unchanged schedule must cost zero. Use `ScheduledFuture.cancel(false)` so an
in-flight run finishes.

**This is the highest-value test in Slice B — above AC1 and AC2** — because getting it wrong is
worse than the defect being fixed. See AC14.

### 6a.3 CONSTRAINT 2 — give the reconcile its own fixed phase, at second 50

`TenantConfigLoader.scheduledRefresh` is `@Scheduled(fixedDelayString = ...)`, **not** a cron — so
its phase **drifts** and it will sometimes coincide with second 0 or second 20, differently on every
boot. Any bug that depends on that coincidence would be irreproducible.

Do **not** hang the reconcile off `scheduledRefresh`. Give it `@Scheduled(cron = "50 */5 * * * *")`.
Second 50 is clear of everything already scheduled:

| second | occupant |
|---|---|
| 0 | `orderRelease` **+** `OutboxDispatcherJob` |
| 15 | `OutboxDispatcherJob` |
| 20 | `replenish` |
| 30 | `OutboxDispatcherJob` |
| 40 | `releaseExpiredPickingOrdersFromUser` (hard-coded) |
| 45 | `OutboxDispatcherJob` |
| **50** | ← **the reconcile: alone** |

(`OutboxDispatcherJob` is `*/15 * * * * *`. `TenantPoolEvictor` and `TenantConfigLoader` are both
`fixedDelay` 5 min, so they drift and are not phase-guaranteed — another reason not to share their
hook.) Thread-pool contention is **not** a concern: `POOL_SIZE = 10`, and at second 50 the reconcile
runs alone.

### 6a.4 ✅ CONSTRAINT 3 — per-tenant blocking, now BOUNDED IN CODE by SBDEV-3204

**⚠ RESOLVED / DOWNGRADED 2026-09-02 (SBDEV-3204). Rev 1 of this section was wrong**, and so was the
Slice A javadoc it cited. It said the reconcile "can block indefinitely" because
`loginTimeout`/`socketTimeout` "both default to infinite". The defaults are indeed 0, but that does
not produce an unbounded block for any failure shape that can be reproduced. Measured on pgjdbc
42.7.8, no properties set: a dropped SYN fails in **10.2s** (the documented `connectTimeout`
default), and accept-then-silence fails in **5.2s** (mechanism unidentified; `connectTimeout`
provably does not govern it). Both connects measured as a pair (the raw probe plus
`new HikariDataSource`): **21.3s** SYN-drop, **11.4s** accept-then-silence. So the real cost is
**~11–21s per unreachable tenant per cycle**, bounded.

⚠ **SUPERSEDED 2026-09-02 — SBDEV-3204 SHIPPED (`779851a1`, `b862700d`), so those numbers are an
upper bound rather than a current measurement.** They were taken with pgjdbc's bare defaults. 3204
now sets the values explicitly: the one-shot probe gets `connectTimeout=5s` **and**
`socketTimeout=10s`, the pool gets `connectTimeout=10s` and deliberately **neither**
`socketTimeout` nor `loginTimeout`. Re-measure before quoting a figure. Two of its findings are
worth carrying forward here: the post-handshake stall **was** real and unbounded (it needed a
fake server that speaks the PG wire protocol and then stalls — `StallingPostgresServer`; the probe
did not return in over seven minutes on loopback, and returns in ~6.9s with the bound), and
`loginTimeout` must **not** be used on the pool, because pgjdbc implements it as a watchdog thread
that abandons a worker which then blocks on a read bounded only by the absent `socketTimeout` —
leaking a thread and an FD per Hikari retry.

That changes this from a correctness constraint into a **throughput** one, and it is why Constraint 2
(§6a.3) already handles it: the reconcile has its own fixed phase at second 50, so a slow cycle
delays only the next reconcile, never the every-minute jobs.

**What remains genuinely unbounded** is narrower and unproven: a *post-handshake* read, i.e. a tenant
DB that connects, authenticates and then stalls mid-query. `socketTimeout=0` leaves that with no
bound. Not reproduced — it needs a server that speaks the PG wire protocol and then stalls. Tracked
on **SBDEV-3204**, which was first parked in backlog (Nam, 2026-09-02) on the grounds that the
concrete harm was the false claim rather than the code, and that touching
`TenantDynamicRoutingDataSource` — a file on every request path — was not justified by a hazard
nobody had demonstrated. ✅ **That reasoning was overtaken: a peer session then DEMONSTRATED the
hazard and shipped the bound** (PRs #280/#281). The parking decision was correct given the evidence
available; it stopped being correct the moment the hazard was reproduced.

**Neither of rev 1's two "acceptable answers" survives, for reasons worth keeping:**

1. **Reading through the `@Cacheable` sysprop cache does nothing here.** The `sysprops` cache is
   Caffeine with a **2-minute TTL** (`CacheConfig`), and the reconcile runs every 5 minutes — so the
   entry is always expired and every cycle does a real DB read regardless. Rev 1's stated *downside*
   was also wrong: a direct `los_sysprop` edit is picked up within 2 minutes by TTL expiry, with or
   without `@CacheEvict`. And it bounds the wrong path — `SyspropService` reads route through the
   tenant's Hikari pool (bounded by `connectionTimeoutMs`, 30000 everywhere) only *once the pool
   exists*; pool **creation** is the unbounded-in-theory path, and a newly-activated tenant is
   exactly the case the reconcile exists to serve.
2. **Bounding is right in principle but is not this ticket's job**, and the fix rev 1 described was
   partly dangerous — see the warning below.

**⚠ Do not add a pool-wide `socketTimeout`.** Slice A's javadoc prescribed
`cfg.addDataSourceProperty("socketTimeout", …)` "for the Hikari half". pgjdbc's `socketTimeout` is a
**per-read** timeout applied to every statement on the connection, so pool-wide it is a de-facto
global query timeout. `StockSummaryExportJob` holds a streaming cursor across every `itemdata` row;
a modest value would kill it mid-stream. If anyone bounds this later: establishment
(`connectTimeout`/`loginTimeout`) on the pool, read timeouts only on the one-shot probe.

⚠ **`tenant_discovery` does NOT exist in the H2-backed test contexts.** Observed 2026-09-02 while
running `Sbdev3017TrancheGateContextTest`: Hibernate's schema export fails with
`Syntax error in SQL statement "create table tenant_discovery (... key varchar(50) ...)"; expected
"identifier"` — `key` is a reserved word in H2 and the column is not quoted. The failure is logged at
WARN and swallowed, so the table is simply absent and every test still passes. Pre-existing, unrelated
to this ticket's changes — but **directly relevant to AC2**: any code that reads
`tenant_discovery.timezone` will `relation "tenant_discovery" does not exist` in exactly those test
contexts, and the DDL WARN gives no hint that a *later* test failure is caused by it. If AC2 takes the
landlord-side zone, either quote the column, rename it, or provide the row through a mock rather than
the schema.

**One thing this ticket CAN take for free.** The firing zone no longer needs a tenant-DB read at all:
`tenant_discovery.timezone` in the **landlord** DB records the warehouse's operating zone. Verified
2026-09-02 across both environments — prd hydra/nywh `America/New_York` (agreeing with that tenant's
`los_sysprop.System Time Zone`), and all four dev rows populated with `active` mirroring
`tenant_db_configuration.active` exactly. Two caveats: the join is a **string convention, not an
FK** (`realm = tenant.name AND key = warehouse || '-' || tenant.name`; note `key` is
`<facility>-<tenant>`, the reverse of the routing key), and the column is **`NOT NULL DEFAULT
'UTC'`** — so a warehouse onboarded without setting it silently gets UTC, indistinguishable from a
deliberate UTC choice. For a US warehouse that fires the 3:00 overnight jobs at 22:00 or 23:00 local
the previous evening. **AC2 needs a criterion for this**: cross-check the landlord zone against the
tenant's `System Time Zone` sysprop and refuse or warn loudly on a UTC default that disagrees — that
cross-check is the only thing that makes the two cases distinguishable. The `*_TIMER_HOUR`/`_MINUTE`
values still come only from tenant `los_sysprop` (verified on hydra: no landlord copy), so the
tenant read does not disappear.

### 6a.5 What order release and replenish actually experience under D′

Stated explicitly, because "we are changing how the every-minute jobs are scheduled" is alarming
and in this case not what happens:

- **Their schedule does not change.** Both are `*`/`*` on every tenant, so their crons
  (`0 * * * * *`, `20 * * * * *`) are **zone-invariant** — a per-minute cron fires at identical
  instants in every zone. Under D′'s zone-invariant collapse (§4a) they form **one group each → one
  trigger each → exactly today's arity.** AC1 and AC2 are effectively no-ops for these two jobs.
- **They gain contention isolation.** Today one lock covers the whole job and the job loops all
  tenants inside it, so if tenant A's run exceeds 60s the next tick gets `false` from `tryLock` and
  **every tenant is skipped that minute**, at DEBUG. One slow tenant starves all tenants, once a
  minute, invisibly. Under the per-tenant lock of §4a the next tick proceeds for the other tenants
  while A finishes.

So for the two most important jobs, Slice B is **schedule-neutral and contention-positive**. That is
the strongest single argument for D′ and it should be in the PR description.

---

### 6a.6 ⛔→✅ CONSTRAINT 4 — the reconcile must NOT re-derive an existing schedule (H2)

**Found by review, 2026-09-02, and it defeated AC14's central guarantee from a direction the AC did
not consider.** Recorded as a section because the reasoning generalises well past this ticket.

AC14 makes the reconcile a strict no-op when the desired trigger set is unchanged. That is a real
guarantee — but **a no-op diff only stabilises anything if its INPUT is stable**, and the input here
is `probeForReachableTenant()`, documented in its own javadoc as *"stops at the FIRST reachable
tenant … iteration order over the cache copy is arbitrary"*. Before this ticket that election
happened **once per process**. Converging registration re-ran it **288 times a day**.

The review then checked whether tenants actually disagree, read-only across four live DBs. They do:

| DB | `STOCK_SUMMARY_EXPORT_TIMER_HOUR` | `ORDER_TIMER_HOUR`/`_MINUTE` |
|---|---|---|
| `wms2-hydra` (**prd**) | `3` | `*` / `*` |
| `nywh-hydra-uat` | `3` | `*` / `*` |
| `c1wh-shipitez-uat` | **`18`** | `*` / `*` |
| `wsl-wineco-uat` | **`17`** | `*` / `*` |

So a transient outage on whichever tenant happens to iterate first re-elects a different source, and
`register` faithfully does what it is told: cancel `stockSummaryExport` at 03:00 and re-schedule it
at 18:00, then flap back next cycle. The same event re-registers `orderRelease` and `replenish`,
which the table confirms are `*`/`*` on prd — **the once-per-minute jobs whose cancel/re-add AC14
prices at up to 288 lost order-release minutes a day.** Converging registration would have
converted that worst case from *impossible by construction* into *driven by tenant health*.

**Decision (Nam, 2026-09-02): ADDITIVE-ONLY.** The reconcile fills gaps and never re-decides.
Three options were put; the other two were rejected for reasons worth keeping:

- **Sticky source** (remember the elected tenant, keep it while reachable) — the review's own
  recommendation, and it does remove the flap. Rejected because the remembered value *is* the
  defect: "which single tenant's sysprops schedule everyone" is §1.1, the thing AC1/AC2 deletes. It
  also needs mutable singleton state, which `SingletonTenantStateArchTest` had already rejected
  once in this very change.
- **Deterministic election** (lowest reachable key) — removes the coin flip but **not** the flap:
  the source still moves whenever that tenant's reachability changes, i.e. exactly during an
  incident. It delivers trigger churn at the worst possible moment while *looking* like a fix.

**What additive-only costs, stated plainly:** a timer sysprop edit does not take effect until the
container restarts. That is exactly today's behaviour, so it is not a regression — it drops a bonus
this document had advertised, not a requirement. And a job registered with the **wrong** cron
(arbitrary boot tenant, §1.1, live today) will never self-correct; it holds that schedule until
restart. AC1/AC2 is the real fix; this class must not half-fix it by flapping.

**What it buys beyond the flap:** three separate review findings collapse to non-issues — H2 itself,
§6a.4's cache-refresh race producing a bogus source election, and half of the `CRON_JOB_SHOW_LOG`
staleness question — because the code stops making the decision that created them. AC14's guarantee
also stops depending simultaneously on sysprop stability, probe determinism, and the
`TenantConfigLoader` `clear()`-then-repopulate window.

⚠ **Consequence for `register`:** its cancel-and-reschedule half is now reachable **only** from a
non-reconciling pass, i.e. the boot path, where the registry is empty and the diff always registers.
So in production it currently only ever registers. The path and its tests are retained as the
specification AC1/AC2 needs immediately (per-tenant triggers must be re-derivable when the tenant
set changes) and are labelled as not-yet-reachable in the javadoc. **If AC1/AC2 does not land,
delete it rather than leaving tested-but-unreachable code.**

⚠ **Three tests went VACUOUS-but-green for one commit** when additive-only landed —
`showLogChangeReRegistersNothing`, `blankSyspropsDoNotCancelAWorkingTrigger` and
`aRejectedReplacementDoesNotRetireTheIncumbent` all stopped reaching `register` at all, and still
passed. Only a mutant revealed it. They now drive the non-reconciling pass explicitly. **Changing
which path a test exercises can silently empty it; re-run the mutants after any such change.**

---

## 7. Acceptance criteria

Carried from the ticket; restated here so the document is self-contained.

- **AC1** — Each tenant's jobs fire on that tenant's `*_TIMER_*` sysprops. Verify on UAT, which has
  three distinct export hours.
- **AC2** — Each tenant's trigger uses that tenant's IANA zone via
  `TimezoneService.getWarehouseZoneId()`. Verify Hydra fires at 03:00 **New York**.
- **AC3** — No job executes more than once per tenant per scheduled occurrence. A test must prove
  the N² shape is absent, not merely that one tenant works.
- **AC4** — Tenants (or groups) whose triggers fire at the same instant all process. A test must
  prove the lock no longer serialises across them — §2.2 is the easiest regression to reintroduce.
- **AC5** — ✅ **SATISFIED BY DESIGN (2026-09-02).** Exactly one container carries `app.cron=true`
  (Nam), and deploys are recreate, so no second holder of locks `100001L`–`100006L` ever exists,
  including mid-deploy. No cutover, no dual-locking, no `app.cron=false` ceremony. What remains is a
  **runbook guard**: this reverses if `app.cron=true` is ever set on the 2–3-replica api tier, or if
  a second cron container appears.
- **AC5a** — ⚠ NEW, from §3.2: `OutboxDispatcherJob` (`100008L`) and `RestIdempotencyCleanupJob`
  (`100007L`) **still use the one-key lock form** after this change. A test or ArchUnit rule should
  pin it. Justification, corrected: those two jobs are **correct as they are and are not in this
  ticket's scope** — a single process-wide lock is right for them. (Rev 1 justified this as
  preventing a double-send to OMS; that was **wrong** — `findAndClaimPending` uses
  `FOR UPDATE SKIP LOCKED` plus an atomic status flip, so two dispatchers cannot claim the same row.
  The real cost of losing the guard is a doubled OMS request rate and a ~5-minute
  `STALE_INFLIGHT_TIMEOUT` re-send window.) "Tidy up the remaining one-key call sites" is the future
  refactor this AC exists to stop.
- **AC6** — `JobMetrics` per-tenant tags survive: no cardinality regression, no double-counting, and
  any whole-run gauge whose meaning narrows is either re-scoped or renamed.
- **AC7** — no scheduled occurrence can exhaust the **landlord** pool — not the tenant pools; see
  §2.3.1 for why they differ and why only this one bounds the lock. **Downgraded from a blocker to
  a stated arithmetic bound**: `max simultaneous lock-holders ≤ effective landlord cap`. Measured
  2026-09-02: ~20 idle landlord connections on prd against a peak requirement of ~2, so headroom is
  large and the in-repo `maximum-pool-size=2` is demonstrably not the running value. Read the real
  cap from the Portainer stack env or `hikaricp_connections_max{pool="LandlordHikariPool"}`, write
  the arithmetic down, and do **not** raise anything speculatively. Tenant caps are already
  comfortable: prd 5; uat 6/6/6/10.
- **AC8** — Assertions mutation-checked with PIT scoped to each changed class; every kill message
  names the mutant.
- **AC9** — Full suite compared against a freshly-measured `develop` baseline. Measure it fresh —
  `develop` moved twice during Slice A.
- **AC14** — ✅ **DONE 2026-09-02.** **The reconcile is a strict no-op when the desired trigger set
  is unchanged.** The diff lives in exactly one place — `SchedulingConfiguration.register(...)`,
  which compares a `TriggerSpec(cronExpression, zoneId)` and returns before touching anything when
  it matches — so `configureAllTasks` is idempotent **by construction** rather than by a caller
  remembering to check. `cancel(false)`, so an in-flight run finishes.
  Pinned by `SchedulingReconcileIdempotencyUnitTest` (16 tests): two reconciles change nothing; ten
  reconciles still leave exactly six triggers rather than 66; the no-change path stays at DEBUG.
  **Confirmed live on prd 2026-09-02** that the stakes are as stated: `ORDER_TIMER_HOUR`,
  `ORDER_TIMER_MINUTE`, `REPLENISHMENT_TIMER_HOUR` and `REPLENISHMENT_TIMER_MINUTE` are **all `*`**
  on hydra/nywh, so both jobs are genuinely once-per-minute and a cancel-and-re-add cycle at a
  5-minute cadence would drop up to 24×60/5 = **288 order-release minutes a day — 20% of them**.
  ⚠ **Two invariants were added that §6a.2 did not ask for, because a mutant found the gap:**
  a **failed derivation must not cancel a working trigger** (blank timer sysprops are a data
  problem, and cancelling on a failed read converts it into six silently unscheduled jobs), and the
  replacement is **scheduled BEFORE the incumbent is retired** (cancel-first would strand a job
  permanently whenever `schedule()` throws). The second is the one PIT structurally cannot express —
  see §7a step 2.
  ⚠ **AC14 is now satisfied twice over, and the second way is the one that matters.** The diff makes
  an unchanged set free; **§6a.6's additive-only decision means the reconcile never re-derives an
  existing schedule at all**, so the guarantee no longer depends on the derived value being stable.
  That was necessary, not belt-and-braces: review finding H2 showed the diff's *input* is a
  re-elected arbitrary tenant, so a correct diff over an unstable input would still have flapped.
  **A no-op diff only stabilises anything if its input is stable.**
  ⚠ Consequence: `register`'s cancel-and-reschedule half is reachable only from a non-reconciling
  pass and therefore, today, only from boot — where it always registers. It is retained as AC1/AC2's
  specification and labelled as such in the javadoc; **delete it if AC1/AC2 does not land.**
- **AC15** — ✅ **DONE 2026-09-02.** The reconcile runs on its **own fixed phase**
  (`@Scheduled(cron = "50 */5 * * * *")`), not on `TenantConfigLoader`'s drifting `fixedDelay` hook,
  so it cannot intermittently collide with `orderRelease` (second 0), `replenish` (second 20),
  `releaseExpiredPickingOrdersFromUser` (second 40) or `OutboxDispatcherJob` (0/15/30/45).
  Pinned three ways rather than by restating the table: a literal pin on the cron plus an assertion
  that `fixedDelayString` is **empty** (a drifting phase is the failure mode); a **derived**
  collision check that expands the seconds field of each of the six registered `CronTrigger`s and
  asserts second 50 is in none of them; and a second derived check that reads
  `app.cron.outbox-dispatcher` and `app.cron.cleanup-rest-idempotency` **from
  `src/main/resources/application.properties` on disk** and asserts the same.
  ⚠ That last one reads from disk deliberately: `src/test/resources/application.properties`
  **shadows** the main file on the test classpath and sets `app.cron.cleanup-rest-idempotency` to a
  placeholder, so a `getResourceAsStream("/application.properties")` would have graded the wrong
  file and passed for the wrong reason.
- **AC10** — ✅ **DECIDED and IMPLEMENTED 2026-09-02. Nam chose CONVERGING REGISTRATION.**
  Registration is no longer one-shot: the boot path retains each job's `ScheduledFuture` and a new
  `@Scheduled(cron = "50 */5 * * * *") reconcileSchedules()` re-derives every job's schedule every
  five minutes and applies **only what changed**. Neither bad branch of the original dilemma is
  taken — the reconcile does not block on all N tenants, and it does not freeze a partial schedule
  for the process lifetime.
  Three things it buys that one-shot boot could not, all now pinned by tests: a tenant whose DB was
  down at boot is scheduled once it recovers instead of waiting for a deploy; a timer sysprop edit
  takes effect within 5 minutes instead of requiring a container restart (today **nothing** re-reads
  it); and AC11's activation/deactivation liveness comes free.
  ⚠ **The reconcile is ADDITIVE-ONLY** (Nam, 2026-09-02, after review finding H2): it registers
  jobs that have **no** trigger and never re-decides one that is already registered. See §6a.6 —
  this is the decision that keeps AC14 meaningful, and it means a timer sysprop edit still needs a
  restart. AC10 only ever asked that a tenant down at boot get scheduled once it recovers, which it
  does.
  ⚠ **No mutable state was needed.** The scheduler is resolved from the injected
  `ApplicationContext` per call rather than captured in a field. An earlier draft used a
  `private volatile TaskScheduler` and `SingletonTenantStateArchTest` **correctly failed the
  build** — a `@Configuration` bean is a singleton, so mutable instance state on it is shared by
  every tenant in the process. Resolving per call also deleted the subtlety it replaced: the
  reconcile no longer depends on the boot task having run, so there is no capture ordering to get
  wrong and no null branch to handle.
- **AC11** — ⚠ NEW: **tenant activation and deactivation after boot take effect on the next tick,
  in both directions.** This is current behaviour; a test must prove D′ preserves it rather than
  freezing membership at registration.
- **AC12** — ⚠ NEW: **the lock key contains no group-membership-derived component.** An ArchUnit or
  unit pin, because "a stable hash of the tenant set" is the obvious implementation, it is unsound
  (§4a), and revision 1 of this very document recommended it.
- **AC13** — ✅ **CLOSED 2026-09-02** (folded in on the same day). **The admin trigger endpoints
  have a stated, gated, tenant-correct scope.** Specifically: (a) ✅ `a33a59ac` —
  `triggerUpdateStock` and `triggerReleaseExpiredPickingOrdersFromUser` now carry an
  authorization annotation; they carried none. (b) ✅ `3849a223` — each of the four
  job-triggering endpoints has an explicitly decided and tested scope (**Option A**: "run now"
  means the caller's tenant, fail closed when it is absent), because `isCronJob` **was** a dead
  parameter in four of six jobs (§5.1a) so three of them silently fanned out across every
  tenant. ⚠ `StaleClubBatchCleanupJob` is **not** covered — see §5.1a. And (c) if the decision is that an operator's "run now" means their own
  tenant, that is a **behaviour change on shipped endpoints** and must be called out in the PR
  description, not just in code. Note `triggerOrderReplenish` fires **two** jobs, so it needs the
  decision applied twice.
- **AC2′** — ⚠ NEW: scope AC1 and AC2 to **the five jobs that read a timer sysprop**;
  `releaseExpiredPickingOrdersFromUser` is sysprop-free and zone-invariant, so AC1/AC2 cannot apply
  to it and leaving them unscoped implies coverage that is impossible. Separately, a tenant whose
  zone falls back to UTC must be **named in the registration provenance line**.

---

## 7a. Suggested sequencing

Derived from the blast-radius measurements, not from preference.

2. ✅ **MERGED `on dev` 2026-09-02 — converging, additive-only registration (AC10, AC14, AC15).**
   `wms2-api` **PR #283**, merge commit **`951b854c`** (feature commit `670a7f76`), rebased onto
   `b862700d` (i.e. on top of SBDEV-3204's #280/#281). **Full suite 6173/0 vs a freshly-measured
   baseline `b862700d` 6144/0** — exactly +29, matching the new class's 21 `@Test` plus one
   `@RepeatedTest(8)`, so two independent instruments agree on the delta. Post-merge verified on
   `origin/develop`: `RECONCILE_CRON` present, `onlyIfMissing` gate at all six call sites,
   `registrationLock` present, **zero** `volatile` fields, `app.cron` gate intact, test class present.
   ⚠ Merging to `develop` is a dev deploy; this change carries **no Flyway migration**, so no schema
   step ran. The first `Schedule reconcile: no changes, nothing rescheduled` INFO heartbeat on the
   dev cron container is the live confirmation the mechanism was picked up by Spring.
   Nam approved converging registration; the pin was written first, as this step required.
   `SchedulingConfiguration` now retains each job's `ScheduledFuture`, diffs in one place
   (`register`), and reconciles on `@Scheduled(cron = "50 */5 * * * *")`. **No grouping code yet —
   today's one-trigger-per-job derivation is unchanged, so this slice is schedule-neutral**; it
   converts one-shot registration into converging registration and nothing else. That is what makes
   AC1/AC2 safe to build on top.
   Diff: +237/−29 in one main file (the −29 is six duplicated `schedule` + `Configured` blocks
   collapsing into `register`), plus a new 16-test `SchedulingReconcileIdempotencyUnitTest`.

   **What the evidence actually was, and why it is not a pre-fix red.** The reconcile is new code,
   so no prior state exists in which these assertions fail. PIT scored **118/118 killed, 0
   survivors** scoped to the class — and that score was **blind to the most dangerous mutant in the
   change**. Three mutants were then applied by hand, all killed with attributable messages:

   | mutant | PIT can express it? | killed by |
   |---|---|---|
   | delete the strict-no-op branch (cancel-and-re-add every cycle) | partly | **7** tests |
   | fold `CRON_JOB_SHOW_LOG` into the diff key | no — needs a new record field | `showLogChangeReRegistersNothing` |
   | **swap schedule-then-cancel into cancel-then-schedule** | **no — statement reordering** | **1** test, and it did not exist until the mutant was tried |

   ⚠ **The reordering mutant is the lesson, and it is the second time on this ticket that a
   hand-reasoned mutant beat a perfect PIT score.** Nothing in the original 15 tests asserted the
   *ordering* my own javadoc claimed, so cancel-first — which strands a job with no trigger for the
   life of the process whenever `schedule()` throws — would have shipped behind a 100% mutation
   report. The fix was a new test, not a new comment. **Statement reordering is in no mutation
   operator's vocabulary; a per-invariant human mutant list earns its place alongside PIT.**

   ⚠ Also fixed *because* PIT said something — **twice, the same shape.** Six `return register(...)`
   sites produced **equivalent mutants** (unkillable, and indistinguishable in a report from a real
   assertion gap) because `register` could only ever return `true` or throw; making it `void` with an
   explicit `return true` per call site turned all six into killed mutants. Later `onlyIfMissing`'s
   skip-branch `return true` did the same thing, because `configured` is discarded on the reconcile
   path — fixed by cross-checking `configured` against a count read from the registry itself and
   logging an ERROR when they disagree, which is a real invariant (a `configureX` reporting success
   without registering) and not just mutant bait. **An equivalent mutant is a signal that the CODE
   carries a value nothing can observe; deleting or observing that value is the fix, not an
   explanation in the report.**

   **Review: 2 lanes, both wrote reports; 14 findings + 4 false claims, all but one fixed.**
   - Code lane: **1 High** — `register`'s get-then-put was not atomic, and boot ∥ reconcile is the
     *expected* case (the reconcile registers at `ContextRefreshedEvent`, before
     `ApplicationReadyEvent`, while the boot task is deferred 5s after it and then probes for up to
     60 attempts). Measured with the lock removed: **1–5 orphaned triggers per run** — live
     `CronTrigger`s with no handle anywhere in the process, never reconciled away because the
     registry then records a matching spec. Fixed with an explicit `registrationLock` covering the
     whole derive-diff-swap-record sequence.
   - Plus 4 Medium and 8 Low, all fixed, including: a job with **no** trigger was reported as
     "no changes" at DEBUG (now an unconditional WARN naming the missing jobs); a healthy reconcile
     logged nothing at all (now an INFO heartbeat — a once-per-process line would have needed
     mutable singleton state); and the `TenantConfigLoader` `clear()`-then-repopulate race now has
     its tell named in the WARN ("if both lists are empty this is a snapshot during the cache
     refresh, not an outage").
   - ⚠ **The second High was H2, a DESIGN dispute — see §6a.6.** It defeated AC14's guarantee from a
     direction the AC never considered, and it is the reason this slice is additive-only.
   - Fact-check lane: **4 false claims, and all four were completeness claims** — "every other
     second in this process is taken" (54 of 60 seconds are free, and second 0 holds *four* of the
     six jobs, not one), "the only one where the reconcile runs alone", "read one line above every
     `register` call" (two or three, at all six sites), "neither `@Scheduled` job" (there are four;
     the test covers the two cron-valued ones). **Every quantitative claim reproduced exactly.**
     Same signature as SBDEV-3169's review, now with a second independent confirmation.
   - One claim of mine it did NOT break but narrowed usefully: the advisory-lock mitigation covers a
     *simultaneous* double fire only. The two triggers live during a swap differ precisely in their
     cron, so normally they fire at **different** instants and both runs happen — one extra run on
     the retiring schedule. Acceptable, but not the "one run plus one skip" I had written.

0. ~~**If converging registration is approved, write the AC14 reconcile-idempotency pin FIRST**~~
   ✅ superseded by step 2 above.
0b. ✅ **MERGED `on dev` 2026-09-02 — AC13(b), tenant scope. AC13 fully closed.** `wms2-api`
   PR #279 `3849a223`. Nam chose **Option A**: "run now" means the caller's tenant. The four jobs
   that ignored `isCronJob` now resolve `TenantContext.getCurrentTenant()`, refuse when it is absent
   (fail closed), and write the untagged fleet success gauge on scheduled runs only.
   **The `app.cron` container's sweep is unchanged** — `SchedulingConfiguration` untouched, it passes
   `true` for all six jobs, the `findByActiveTrue()` block was only wrapped in `if (scheduled)`, and
   151 existing `doCalculation(true)` test call sites stay green.
   ⚠ **`StaleClubBatchCleanupJob` was NOT fixed and is strictly worse than the four that were**: it
   calls `findByActiveTrue()` unconditionally and uses `isCronJob` only to skip the sysprop
   activation check. Latent solely because nothing calls it with `false`. Fix the scoping in the same
   change as whatever gives it a non-scheduled caller.
   ⚠ **The advisory lock stays job-wide** — a manual trigger for one tenant can still be skipped
   because another tenant's scheduled run holds it. That is AC14/AC15's subject.

0. ✅ **MERGED `on dev` 2026-09-02 — AC13(a), the admin-endpoint gate.** `wms2-api` PR #278
   `a33a59ac` (one `@RequiresFunction` + two pins moved + a durable class-level assertion) and
   `wms2-web-ui` PR #108 `c160190` (three false Cypress button↔endpoint annotations corrected).
   ✅ **AC13(b) — tenant scope — was closed the same day, by step 0b above (`3849a223`).** This
   step recorded it as open when written; that is why 0b sits above it.

1. ✅ **DONE — the metric regression pin** (§5.1.1), shipped as PR 1 (#276 `e174dfbc`):
   `markLastSuccess` withheld when one
   tenant of two fails — against current code, where it must pass. Without it the refactor's most
   consequential regression is invisible to the whole existing metric suite.
2. **Confirm the two environment facts** that the repo cannot answer: the running
   `LandlordHikariPool` cap (§2.3.1) and whether exactly one container carries `app.cron=true`
   (§3.3). Both change the design's constraints, and both live in Portainer.
3. ✅ **MERGED `on dev` 2026-09-03 — `StaleClubBatchCleanupJob` converted to D′.** `wms2-api`
   **PR #286**, squash-merged as **`7b7db3b6`** (feature commit `a35cab5a`), branch
   `bugfix/SBDEV-3198-dprime-stale-club`, rebased onto `e818ff11`. **Full suite 6216/0 vs a
   freshly-measured baseline `e818ff11` 6173/0** — exactly +43, cross-checked against the five
   changed test files' own counts including `@ParameterizedTest` cases. ⚠ No Flyway migration in
   this diff, so merging carried no schema step; the dev-deploy trigger is the merge-to-`develop`
   push itself. It is the
   smallest job (77 lines), has **2** `doCalculation` call sites in tests, and uses `JobMetrics`
   **not at all** — zero metric blast radius. ⚠ The plan's "already honours `isCronJob`" was
   **false** (§5.1a correction): the flag only ever skipped the activation check. Moot now — see
   below.
   **Measured before touching it: `STALE_CLUB_BATCH_CLEANUP_ACTIVATED = false` on all four UAT
   tenants AND on prd hydra.** The job is inert everywhere, so this conversion changes no live
   behaviour. It is the end-to-end proof of the shape, not a fix for a live symptom; the live symptom
   (three distinct export hours) is step 4's `stockSummaryExport`. UAT confirms the plan's grouping
   table exactly: all four at 03:00, zones NY/LA two-and-two → **two `(cron, zone)` groups**.

   ⚠ **PR #286 merged before independent review completed** — the merge (2026-09-03T13:46, Nam) landed
   while a code-review lane and a fact-check lane were still running in a separate session. The review
   found **1 High, 6 Medium, 9 Low**; the fact-check lane checked 20 claims in this block (16 pass, 2
   fail — see the two corrections below and in §7a step 3's design-decisions list; 5 unverifiable, DB
   MCP unreachable). Full reports:
   `sbdocs/1-Projects/wms2/plan/SBDEV-3198-evidence/step3-review-code.md` and
   `sbdocs/1-Projects/wms2/plan/SBDEV-3198-evidence/step3-fact-check.md`.

   **The High (H-1) is load-bearing for step 4**, not cosmetic: `AdvisoryLockService` kept ONE
   `ThreadLocal<Connection>` shared by both lock forms, so the dual-lock mitigation already decided
   above (§7a step 3's "MUST READ" note) was unimplementable against the merged API — attempting it
   would silently leak the one-key connection and exhaust the landlord pool (`maximum-pool-size=2`)
   within two ticks. Fixed (separate slots per form, mutation-verified) along with all Medium findings
   and 5 of 9 Lows (L-6/L-7/L-8 deliberately deferred as design tradeoffs, not correctness bugs; L-9
   was informational).

   Because #286 was already merged, the fixes could not be pushed onto it. They ship as a **follow-up
   PR** off fresh `origin/develop`, branch `bugfix/SBDEV-3198-dprime-followup` — same pattern as the
   SBDEV-3204/junit-bom follow-up earlier this session. **`wms2-api` PR #287**, based on `7b7db3b6`.
   Round-1 commit `adb141b1`: full suite 6225/0/67 vs a derived develop baseline of 6218/0/67
   (`a35cab5a`'s measured 6216 + `#285`'s 2 unrelated tests, which predate this branch) — exactly +7,
   matching the 7 new `@Test` methods added.

   ✅ **Round 2 — #287 was itself independently reviewed before merge**, closing the same gap that
   let #286 land unreviewed: 0 High, 3 Medium, 7 Low (5 fixed, 2 needed no action). The one that
   mattered — **M-A**: M-3's fix (round 1) was code-correct but invisible to the suite, since every
   fixture used a fixed non-invariant cron where `resolvedZone().getId()` and `spec.zoneId()` always
   agree; one fixture even hard-coded that false equality. Added a zone-invariant/UTC-resolved test
   case, mutation-verified against the reviewer's exact mutant (revert the caller to `spec.zoneId()`:
   86 green before the fix, 1 red after — the new test). Reports:
   `sbdocs/1-Projects/wms2/plan/SBDEV-3198-evidence/pr287-review-code.md` and
   `pr287-fact-check.md`. Round-2 commit `039ca330`: **full suite 6226/0/67**, exactly +1.

   ✅ **MERGED `on dev` 2026-09-03 — PR #287, squash-merged as `3941fb26`.** `develop` now carries
   both #286 (step 3's shape) and #287 (this review's fixes) — including the H-1 fix that step 4
   depends on. Step 3 is fully closed; step 4 (`StockSummaryExportJob`) can proceed.

   **Design decisions made in this slice, each stated so it can be disputed:**
   - **`TriggerSpec` is its own public record** with a single `of(cron, zone)` factory that applies
     the zone-invariant collapse, so registration and fire-time derivation cannot disagree. The
     job's `deriveSpecForCurrentTenant()` is the ONE derivation; `SchedulingConfiguration` calls it
     per tenant to discover groups, `runFor(spec)` calls it per tenant to decide membership.
   - **The collapse rule is STRICT**: zone-invariant only when minute, hour, dom, month, dow are all
     `*`. §4a's phrasing ("day-and-below fields are wildcards") would also collapse `0 30 * * * *`,
     which is NOT invariant for half-hour-offset zones (`Asia/Kolkata` UTC+5:30). Every warehouse is
     in a whole-hour US zone, so the looser rule would be right by accident — the wrong kind of right
     for a grouping key. ⚠ **Corrected 2026-09-03 (independent fact-check on PR #286):** this used to
     say strict covers exactly `orderRelease`/`replenish` and nothing else — false, and the shipped
     `TriggerSpec.isZoneInvariant` javadoc already carries its own correction. It covers **three**
     crons today: `releaseExpiredPickingOrdersFromUser` unconditionally (hard-coded
     `"40 * * * * *"`, no timer sysprop at all), plus `orderRelease`/`replenish` only while their
     `*_TIMER_HOUR`/`_MINUTE` sysprops sit at the `*` default (true on prd hydra and all four UAT
     tenants, measured 2026-09-02) — an operator setting either explicitly removes it from this set.
     Coverage is a property of the sysprops, not of the job.
   - **Lock key is `(100006, tenant_db_configuration.id)`** via `pg_try_advisory_lock(int4,int4)`,
     with `Math.toIntExact` so an id past int4 fails LOUDLY instead of silently colliding. Confirmed
     live: prd `{2}`, uat `{3,7,13,14}`. The one-key job-wide lock is no longer taken by this job.
   - **`doCalculation(Boolean)` is DELETED**, not kept as "the degenerate all-tenants case": after
     D′ its only callers would have been the two unit tests, i.e. dead production code. Those two
     tests (A7/A8) are rewritten against the two-key lock, not removed.
   - **Additive-only is PER SPEC for the grouped job**, not per job — gating on the job name would
     stop a tenant activated with a new zone from ever getting a trigger (AC11). A group whose
     members all moved is never cancelled; it fires into nothing and logs "matched no active
     tenant" so it is visible. For a 03:00 daily job that is one harmless empty fire per day until
     restart.
   - **The grouped job registers FIRST in `configureAllTasks`**, deliberately: it walks every
     tenant's context and restores the caller's afterwards. Running it first makes that restore
     load-bearing (drop it and the five single-trigger jobs read under no context and refuse);
     running it last would leave the restore unobservable and the order silently important. PIT
     reported the restore as three equivalent mutants before the reorder.
   - **Rewritten pin, not deleted:** `scheduleIsReadUnderTheWinningTenantsContext` asserted every
     sysprop read happened under ONE winning tenant — which is §1.1's defect. It now partitions by
     key: the five single-trigger jobs must still read only under the probe tenant (the 58b4902f
     regression it guards), and the grouped job must be SEEN reading under each tenant, including
     the unreachable one. The pin became a positive AC1 assertion.
   - **`NeverMatcherNullBlindnessArchTest` inventory gains `StaleClubBatchCleanupJobUnitTest:2`**
     for two `never().tryLock(eq(JOB), anyLong())` sites. `tryLock(long, long)` declares PRIMITIVE
     longs, so `anyLong()` is required (bare `any()` NPEs at unboxing); declared type read before
     accepting, as the rail demands.

   - ⚠ **A real bug found by a SURVIVING PIT mutant, not by any test.** The grouped walk sets and
     clears a context per tenant, so when the walk ends there is NO context — and a first version
     restored the caller's only in an outer `finally` around the whole method. Everything between
     (the `CRON_JOB_SHOW_LOG` read in the group loop) therefore ran with no tenant, i.e.
     unroutable in production. **Every test stayed green** because the context-sensitive stubs
     return `null` for no context and `Boolean.parseBoolean(null)` is quietly `false`. PIT showed
     it as the additive gate's `containsKey` negation SURVIVING: with the gate off the read
     happened, and no stub could see a read made with no context. Fix: restore immediately after
     the walk, and a pin that the showLog read is under the probe tenant. **A context-sensitive
     stub that returns null on no-context HIDES no-context reads instead of exposing them** — the
     same stub shape that caught the boot-probe regression is blind to this one.
   - PIT also reported `members++` → `--` surviving: an `int` counter only ever asked `== 0`, so
     any non-zero count behaved the same. Replaced by the `boolean` the logic actually uses — the
     same "delete the unobservable value" fix as `registeredGroups` and `register()`'s return.

   - **AC7 arithmetic for this job** (landlord pool = one pinned connection per HELD lock): the
     job's per-tenant locks are taken and released SEQUENTIALLY inside one trigger's run, so a
     group holds at most **1** landlord connection at a time regardless of member count. Groups
     hold concurrently only when they fire at the same instant; UAT's two groups are 03:00 New York
     and 03:00 Los Angeles — **three hours apart, never coincident**. The LA group does coincide
     with `stockSummaryExport`'s hard-zoned 03:00 LA trigger (still on the one-key lock), so the
     process-wide peak this slice can contribute to is **2** holders at 03:00 LA. Against the ~20
     idle landlord connections measured on prd (§2.3.1) that is noise, and nothing here raises a
     pool size.

   **⚠ MUST READ before converting `StockSummaryExportJob` (step 4) — the review's most
   consequential finding, and it is invisible for THIS job only because it is inert.**

   A rolling deploy runs the old and new code concurrently for its drain window. The old process's
   `staleClubBatchCleanup` trigger holds the ONE-KEY lock `100006L` and iterates the whole fleet;
   the new process's holds the TWO-KEY lock `(100006, tenantId)` per tenant. **The two lock spaces
   are disjoint in PostgreSQL** — `pg_try_advisory_lock(bigint)` and
   `pg_try_advisory_lock(int4,int4)` never contend — so during the drain window BOTH run for the
   SAME tenant at the same time, which is exactly the outcome the lock exists to prevent. For this
   job the exposure is nil (`STALE_CLUB_BATCH_CLEANUP_ACTIVATED` is `false` everywhere, both runs
   no-op). **For `StockSummaryExportJob` it is not nil: a concurrent double run is a duplicate full
   stock export to OMS.** Before step 4, decide one of:
   - convert with BOTH lock forms held for one release, then drop the one-key form in the next; or
   - accept and document a short duplicate-export window at every deploy; or
   - suppress the old replica's trigger during drain (out of this ticket's mechanism entirely).
   This is a plan/runbook gap, not a code defect in what shipped here — reviewer-rated Medium for
   this inert job, explicitly "High for the shape" once it lands on a job with a real side effect.

   **✅ DECIDED 2026-09-03 (Nam): dual-lock for one release, then drop the one-key form in the
   next.** `StockSummaryExportJob`'s converting release takes **both** `100006L` (whole-job) and
   `(100006, tenantId)` (per-tenant) before doing its per-tenant work; whichever replica — old
   one-key-only code or new dual-lock code — is running still contends on the shared `100006L`
   form during the drain window, so mutual exclusion holds across the boundary. The follow-up
   release drops the one-key acquisition, leaving only the two-key form, matching the other five
   jobs' end state.
   - **Why not "accept the window" (option 2):** unlike `OutboxDispatcherJob`, which has a real
     DB-level correctness mechanism underneath its lock (`FOR UPDATE SKIP LOCKED` + an atomic
     status flip, §3.2), nothing in this document shows `StockSummaryExportJob` or OMS-side
     ingestion is idempotent against a duplicate full stock export. Absent that guarantee, this
     would be a live, externally-visible production risk traded for less code.
   - **Why not "suppress the old replica's trigger during drain" (option 3):** it needs a
     deploy-orchestration change (drain-aware shutdown) outside this ticket's mechanism, with no
     assigned owner, and it would have to work correctly on every future deploy indefinitely —
     versus a one-time, reversible code change owned entirely by this ticket.
   - **Cost is bounded and already shown affordable:** the extra acquisition pins one additional
     landlord connection only during the overlap window. §2.3.1 measured ~20 idle landlord
     connections against a ~2-connection peak requirement — an order of magnitude of headroom — so
     the "must pair with a pool increase" caveat that applied to this same mitigation shape
     elsewhere (§3.3a) does not bite here.
   - **Pattern reused, not invented:** this is §3.2's own rule — "never change the ID *or* the lock
     form" — applied across a release boundary via expand/contract, rather than a new kind of
     change to review. Apply the same dual-lock-then-drop shape to the four remaining jobs in step
     5 rather than deciding per job.
   - **Open verification item, not yet closed:** confirm which container actually runs
     `StockSummaryExportJob`'s cron and whether §3.3a's recreate/stop-then-start finding (no
     self-overlap) genuinely holds for it before implementing — if it does, the drain window this
     decision guards against may not exist in practice, but the dual-lock is retained regardless
     since the doc does not treat that as settled for this job specifically.

   **Second finding worth carrying into every future conversion — unbounded stale-group
   accumulation.** Because the registry key encodes the full spec (`job@cron@zone`), a tenant's
   sysprop edit never produces a *diff* — it produces a NEW key. Additive-only (§6a.6) never cancels
   the old one, so `registrations` grows by one live `CronTrigger` per historical spec for the
   process lifetime, and each stale trigger still runs a full `findByActiveTrue()` walk plus a
   per-tenant derivation every occurrence before logging "matched no active tenant". Free for a
   daily inert job; for a per-minute job it is `(live + stale)` landlord queries per minute — the
   N² cost AC3 exists to remove, reappearing through operational drift rather than through the
   original design flaw. No cap exists today; a restart is the only way to shed accumulated stale
   triggers. Worth a cap or a manual "forget this group" hook before converting `orderRelease` or
   `replenish` (whose sysprop edits are rarer but not impossible).

   **Third — the reconcile's per-cycle cost is now proportional to tenant count, and §6a.4's
   arithmetic (11–21s per unreachable tenant) predates that.** The grouped registration walks EVERY
   cached tenant and reads two sysprops plus a zone from each, every 5 minutes, whether or not
   anything changed (§6a.2's no-op guarantee bounds re-*registration*, not re-*derivation*). At
   UAT's four tenants and SBDEV-3204's 5s/10s bounds, worst case is tens of seconds per cycle; once
   all six jobs are grouped (step 5), that multiplies by six. Acceptable today — the reconcile has
   its own phase at second 50 specifically so a slow cycle delays only itself — but restate the
   arithmetic before step 5 rather than assume it still says "one unreachable tenant".

   Evidence and the review outcome follow when the slice ships.
4. ✅ **MERGED 2026-09-03 — `StockSummaryExportJob` converted to D′.** `wms2-api` **PR #288**, merged
   into `develop` at `f440b534` (branch `bugfix/SBDEV-3198-stock-summary-export` deleted).

   **Submission (`680f1f15`):** implemented the dual-lock mitigation decided above.
   `doCalculation(Boolean)` deleted; `runForCurrentTenant()` replaces it for the two non-scheduler
   callers (`StockCountRestController`, `AdminActionController`), widening their lock from the old
   job-wide one-key form to the caller's own two-key form — a **permanent** gap being closed, not the
   transitional dual-lock one. `TenantSchedule` promoted out of `StaleClubBatchCleanupJob` to a
   top-level type. Full suite **6230/0/67**, exactly +4 vs the 6226 baseline.

   **Review round 1** (`sbdocs/1-Projects/wms2/plan/SBDEV-3198-evidence/pr288-review-code.md` +
   `pr288-fact-check.md`) found **2 High, 4 Medium, 5 Low**. The load-bearing one: the submission's
   one-key lock was held for the **whole trigger fire**, not per tenant — this makes two
   legitimately-concurrent groups of this job (e.g. two zones at the same UTC offset) mutually
   exclusive; the loser silently exports nothing for its whole night at DEBUG, while the *winner's*
   `markLastSuccess()` still advances the shared gauge, so the failure is invisible to freshness
   alerting (H-1). Both of `runFor`'s unlock paths were completely unpinned — deleting either left 124
   tests green (H-2). A pre-membership derivation failure charged `tenantFailure` and withheld
   `markLastSuccess()` for tenants not even in the firing group (M-1). Full findings: H-1/H-2, M-1
   through M-4, L-1 through L-5 — see the report for the complete list.

   **Fix commit `67241727`:** H-1 fixed by scoping the one-key lock PER matching tenant, immediately
   wrapping that tenant's two-key lock (take one-key → take two-key → work → release two-key → release
   one-key, sequentially per tenant) — a busy one-key now costs one tenant this occurrence, not an
   entire group's night; this also substantially mitigates M-3 (the landlord Hikari-pool doubling),
   since both connections are now held only for one tenant's critical section instead of the whole
   walk. H-2 fixed with new `runFor`-level unlock tests, mutation-verified by hand-deleting each
   `finally` body. M-1 fixed by splitting the per-tenant catch to reproduce the *outcome*
   `StaleClubBatchCleanupJob`'s reviewed shape established as correct — via a different mechanism,
   since that reference job has zero `JobMetrics` calls and never needed a split (round-2 fact-check
   corrected the PR description's "mirrors the shape" wording on this point — the outcome matches,
   the code shape doesn't and structurally can't). M-2, M-4, L-1 through L-5 all fixed — see PR #288's
   description for the itemized list. M-3's live landlord-pool-cap verification
   (`landlord.datasource.maximum-pool-size=2` in-repo, never confirmed against a running environment)
   remains explicitly open — DB/actuator MCP access was unavailable this session.

   Full suite **6238/0/67**, +8 over the round-1 baseline (round-2 fact-check corrected this from an
   initially-reported 6237/+7 — the PR description's own test-count arithmetic had missed one new
   `AdminActionControllerUnitTest` case). `runForCurrentTenant()`'s return type changed `void` →
   `boolean` (L-2) so `AdminActionController.triggerUpdateStock` can surface the real outcome instead
   of a hard-coded `true` — three pre-existing tests (`StockSummaryExportJobMetricsUnitTest`,
   `WholeRunSuccessGaugeUnitTest`, `AdminActionControllerUnitTest`) needed matching updates since
   their fixtures assumed the old whole-fire lock scope or the old `void` signature.

   **Round 2 fact-check complete** (`pr288-fact-check2.md`): 9 claims checked, 6 clean PASS + 1
   PASS-with-caveat (the PIT sentence reads as whole-class-scoped to a skim; it's accurate but
   narrowly scoped — the wider class still has pre-existing, untouched-by-this-round survivors) + 2
   numeric corrections (suite count 6237→6238 above; "10 test files touched"→12, all confirmed
   pre-existing) + 1 wording correction (M-1, above). None of these change the merge-readiness
   verdict — all are precision defects in the PR description text, not in the shipped code. PR
   description corrected to match.

   **Round 2 code-correctness review complete** (`pr288-review2-code.md`): **MERGE-READY.** All
   eleven round-1 findings genuinely fixed — the reviewer hand-mutated nine of them, including
   hoisting the one-key lock back out of the per-tenant loop (the literal `680f1f15` H-1 shape) and
   deleting each of H-2's two unlock call sites individually, and could not break the new structure.
   Found 2 new Medium + 2 new Low, all documentation/disclosure defects the H-1 fix itself introduced
   (no logic defects, nothing disputing the design):

   - **N-1** (Medium): the class javadoc claimed `skippedLockBusy` is recorded ONCE PER GROUP FIRE.
     H-1 moved its call site into the per-tenant loop, so it's now per lock-busy TENANT — a
     two-tenant group where both are busy records `2.0`, measured directly by the reviewer's probe.
   - **N-2** (Medium): a fire where EVERY member tenant's one-key is busy now advances
     `last_success_epoch_seconds` with ZERO exports (measured) — at submission the whole-fire early
     return made this unreachable, so this is a real, undisclosed behaviour change on the exact
     drain-window path the dual-lock exists for. Defensible (a busy one-key means an old-code replica
     IS exporting, just on the pre-D′ schedule) but needed disclosure and a pin either way.
   - **N-3** (Low): `AdvisoryLockService`'s own class javadoc still normatively described the pre-H-1
     "stays held throughout" shape — the contract's home document, and what step 5 gets read against.
   - **N-4** (Low): the M-1 fix's comment claimed it "mirrors `StaleClubBatchCleanupJob` exactly" —
     the same overclaim shape M-2 was about, reintroduced one paragraph away from the fix for it.
   - **N-5** (Low, confirmed pre-existing at `680f1f15`, not from this PR): `startTenantTimer()` sits
     just outside its own `try`. Unreachable in practice; left as-is, noted for step 5's clone.

   **Fix commit `8bfb6985`:** N-1 and N-2 fixed in the class javadoc plus two new mutation-verified
   tests (deleting `skippedLockBusy()` kills N-1's test; reverting the busy-tenant `continue` to the
   pre-H-1 early `return` kills N-2's test). N-3 and N-4 fixed as one-sentence javadoc corrections.
   N-5 deferred to step 5 as recommended. Full suite **6240/0/67**, +2 over the round-1 baseline.

   **Merged 2026-09-03 on Nam's explicit instruction** — `f440b534` on `develop`, branch deleted.
   This triggers a dev deploy + Flyway run per this repo's own convention.
5. **Then the four where `isCronJob` is dead** — `CleanUpOldMessagesJob`,
   `ReleaseExpiredPickingOrdersFromUserJob`, `OrderReleaseJob`, `ReplenishOrderJob` in ascending
   test-cost order (17, 17, 28, 50 `doCalculation` sites). Each of these also decides the admin
   console's cross-tenant behaviour (§5.1a), so each needs an explicit statement of what its
   `AdminActionController` trigger does afterwards.

   1/4. ✅ **MERGED 2026-09-03 — `CleanUpOldMessagesJob` converted to D′.**
   `wms2-api` **PR #291**, merged into `develop` at `c360b380` (branch
   `bugfix/SBDEV-3198-cleanup-old-messages` deleted). This job needed the FULL step-4 dual-lock treatment, not
   step 3's simpler inert-job shape: `MessageRepository.archiveMessages` is a plain
   `INSERT INTO message_archived SELECT * FROM message WHERE created < :refDate` with no de-dup
   guard, and `message_archived` has NO primary key (`V2.2.20`'s own comment lists it as one of six
   tables without one) — a rolling-deploy drain window running this twice for the same tenant would
   silently duplicate rows. `runFor()` mirrors PR #288's H-1-reviewed per-tenant lock nesting
   directly, not the whole-fire shape that PR shipped first. `doCalculation(Boolean)` deleted;
   `runForCurrentTenant()` widens AC13(b)'s already-caller-scoped manual trigger to the two-key
   lock form and drops all `JobMetrics`, mirroring step 4's M-2. `AdminActionController
   .triggerArchiveMessages` surfaces the real outcome, mirroring step 4's L-2.

   PIT surfaced the H-2 unlock-path gap and a complete absence of `runForCurrentTenant()` refusal-path
   coverage BEFORE opening the PR — fixed proactively (mirroring `StockSummaryExportJobTest`'s
   `DualLockPerTenantScoping` and `StockSummaryExportJobUnitTest`'s `RunForCurrentTenantLocking`)
   rather than left for review to rediscover. Full suite **6250/0/67**, +10 over the 6240 baseline.

   **Round 1 review complete** (`pr291-review-code.md` + `pr291-fact-check.md`): **0 High, 2 Medium,
   4 Low**. Both self-found gaps (H-2 unlock paths, `runForCurrentTenant` refusal-path coverage) were
   independently re-verified by hand-mutation and confirmed genuinely closed —  every one of nine
   hand mutants killed. Fix commit `15c6a901`:

   - **M-1 fixed**: `runForCurrentTenant()`'s "gauges deliberately NOT recorded" javadoc claim was
     completely unpinned (the new nested test class mirrored 5 of step 4's 6 tests, missing exactly
     `doesNotTouchTheWholeRunGauges`) — added, mutation-verified.
   - **M-2 — DECIDED 2026-09-03, risk explicitly accepted, not a code defect.** PR #288's round-2
     review closed with an explicit instruction to read the running landlord Hikari pool's
     `maximumPoolSize` **before the step-5 fan-out**. PR #291 is that fan-out — it adds the SECOND job
     holding both lock forms simultaneously against an in-repo cap of
     `landlord.datasource.maximum-pool-size=2`, and the deadline was crossed without a reading
     (DB/actuator MCP access unavailable this session again — same obstacle both #288 rounds and this
     round hit). **Nam's decision, asked directly given this was the second round in a row the item
     went unresolved: accept the risk and continue, rather than pause step 5 to chase live DB access.**
     Reasoning recorded: the in-repo cap is 2, each dual-lock job briefly needs both connections only
     during one tenant's critical section (not the whole walk, per H-1's per-tenant scoping already in
     place for every converted job), these are nightly off-peak jobs, and the failure mode if the cap
     genuinely is 2 and two jobs' windows overlap is a misleading log message and a skipped occurrence
     — not data loss or corruption. Cheap hardening applied regardless: the busy-one-key log no longer
     asserts "old-code replica" as the cause when it could equally be pool exhaustion (`tryLock`
     returns `false` for both, indistinguishably). **Not a blocker for parts 2–4 going forward** — the
     live-cap reading remains a nice-to-have, not a gate.
   - **L-1 through L-5 fixed**: `startTenantTimer()` moved inside its `try` (round 2's N-5, explicitly
     assigned to this PR by name); the dual-lock's `V2.2.20` citation corrected (the table already
     tolerates duplicates by design — the dual-lock prevents a rolling deploy from making that routine,
     not preventing novel corruption); `skippedLockBusy`'s per-tenant semantics stated in this job's
     own javadoc and pinned with a two-tenant test; the timer-population change documented
     (informational). Also fixed a stale "FOUR single-trigger jobs" comment in
     `SchedulingReconcileIdempotencyUnitTest.java` the fact-check lane found beyond either review's
     own list.

   **Round 2 review complete** (`pr291-review2-code.md` + `pr291-fact-check2.md`, fresh worktrees at
   fix commit `15c6a901`): **0 High, 0 Medium, 4 Low (all new)**. Every round-1 finding independently
   re-verified by hand rather than by reading — M-1's and L-4's mutants re-killed one at a time (three
   separate assertion lines for M-1; the per-fire-vs-per-tenant discrimination for L-4), every
   quantitative claim re-derived from scratch (full suite, file counts, `NeverMatcher` census), and the
   PIT survivor-parity claim independently confirmed by running PIT against `StockSummaryExportJob`
   itself. Fix commit `685670d6`:

   - **N-1 fixed**: this PR's own description still framed M-2 as "still open... needs to be made,"
     contradicting this doc's own "DECIDED 2026-09-03" record above — corrected to match.
   - **N-2 / N-3 fixed**: the M-2 log reword and the L-1 timer-placement move had each landed on only
     this job. `StockSummaryExportJob` — the other dual-form lock holder, and the file parts 2–4 will
     clone from — still carried both pre-fix shapes verbatim. Both copied over now, before the clone
     could propagate the gap three more times.
   - **N-4 fixed**: L-4's own javadoc fix cited the wrong test method name (the pre-existing
     single-tenant test instead of the actual two-tenant test asserting `2.0`) — corrected.

   Full suite **6252/0/67**, unchanged (all four fixes are javadoc/log-text only, no test changes).
   Two full independent review rounds clean, no open findings. **Merged into `develop` 2026-09-03
   at `c360b380`, on Nam's explicit instruction ("merge #291").** PR:
   https://github.com/SiteBossInc/wms2-api/pull/291

   ✅ **PROPOSED FINDING, discovered 2026-09-03 by PR #293's round-2 review — FIXED via PR #296,
   merged into `develop` at `bb264b87`.** `CleanUpOldMessagesJob.runForCurrentTenant()` (this PR)
   had **no activation-flag check at all** — confirmed by reading the merged code
   (`c360b380:327-334`: `tryLock` → `archiveOldMessages()`, nothing else) and confirmed this is a
   genuine regression, not a deliberate step-4-precedent decision, by reading the commit immediately
   before this job's own D′ conversion (`git show e83d9550`): its pre-D′
   `doCalculation(false)` ran the manual trigger through the same activation-gated shared loop as the
   scheduled path. The D′ conversion silently dropped that gate. Live consequence:
   `GET /v3/adminAction/triggerArchiveMessages` against a tenant with
   `clean_up_old_messages_activated = false` archived that tenant's messages anyway — two full
   review rounds on PR #291 did not catch it, because nobody checked the pre-D′ git history for that
   specific behavior. Per this repo's ticket policy (shipped code — propose, don't silently fix)
   this was raised with Nam rather than folded into PR #293's own diff; Nam confirmed a follow-up
   PR, which shipped as PR #296 (see its own entry below). `OrderReleaseJob`/`ReplenishOrderJob`
   (step 5 parts 3-4) still carry their pre-D′ gated shared-loop shape (`OrderReleaseJob:114-123`,
   `ReplenishOrderJob:147-156`) and must not repeat this when converted. See `pr293-review2-code.md`
   §N-1 for the full evidence chain.

   2/4. ✅ **MERGED 2026-09-03 — `ReleaseExpiredPickingOrdersFromUserJob` converted to D′.**
   `wms2-api` **PR #293**, merged into `develop` at `8c178ed1` (branch
   `bugfix/SBDEV-3198-release-expired-picking` deleted), on Nam's explicit instruction ("merge
   #293"). Commit `02208807` (round 1 fix), based on `develop`'s tip (post-#291 merge, `c360b380`).

   **Idempotency verdict: step-3 (inert) shape, NOT part 1's dual-lock.** The query that finds
   candidate rows (`PickingorderRepository.getPickingOrdersToReleaseExpiredPickingOrders`) filters
   on `po.lockedtooperator = true`, the EXACT column `releaseExpiredPickingOrders()` flips to
   `false`, so a second concurrent run can only match rows the first hasn't committed yet. **The
   load-bearing mechanism (corrected by round-1 review, M-2) is `Pickingorder`'s `@Version`
   optimistic lock, not merely that predicate** — the loser's `save()` (a merge on a detached,
   version-checked entity) raises an optimistic-lock failure that aborts that tenant's remaining
   rows and books a `tenant_failure`, self-healing next minute; `@Version` is also what blocks an
   actual lost-update (a stale run re-releasing an order a live operator claimed in between). No
   dual-lock mitigation needed — but the class javadoc now states the real mechanism, since this is
   the template for parts 3–4 and neither is a single-column flip on a version-locked entity.

   **No group-derivation machinery either** — unlike the three grouped jobs, this job reads no
   sysprop for its schedule at all: one hardcoded fleet-wide `"40 * * * * *"` cron, unconditional
   for every tenant. First of the three single-trigger jobs (`OrderReleaseJob`/`ReplenishOrderJob`,
   parts 3–4) to convert; sets their template — **Nam confirmed the proposed shape ("Go with A")
   2026-09-03** before implementation began.

   **Shipped shape:** `SchedulingConfiguration`'s single unconditional registration unchanged; the
   fire handler now calls `runFor()` (no `TriggerSpec` argument) instead of `doCalculation(true)`.
   Inside it, the job-wide one-key lock wrapping the whole tenant loop is replaced with a per-tenant
   two-key `(RELEASE_EXPIRED_PICKING, tenantId)` lock taken inside the loop (AC4). `doCalculation
   (Boolean)` is gone; `runForCurrentTenant()` replaces the manual-trigger path, widening AC13(b)'s
   already-caller-scoped trigger to the same per-tenant two-key lock (mirroring
   `CleanUpOldMessagesJob`'s M-2/AC13b fix, minus the dual-lock's outer layer).
   `AdminActionController.triggerReleaseExpiredPickingOrdersFromUser` now surfaces the real outcome
   instead of a hard-coded `true`.

   **Self-found via PIT before opening the PR** (mirroring part 1's own self-found-gap discipline):
   `runFor()`'s per-tenant unlock call and `runForCurrentTenant()`'s five refusal/outcome paths had
   zero or weak coverage — PIT reported three `return false` refusal mutants as `NO_COVERAGE`, not
   merely unkilled. Fixed with `PerTenantLockRelease` and `RunForCurrentTenantLocking` nested test
   classes (added the `doesNotTouchTheWholeRunGauges` test proactively this time, learning from part
   1's M-1 review finding rather than waiting for review to find the gap again). PIT kill rate
   67%→81%, zero `NO_COVERAGE` remaining; the two residual boolean-return survivors on
   `runForCurrentTenant()` were hand-verified as a PIT bytecode-line-attribution artifact (a
   source-level mutation of the identical semantic change IS caught), matching the accepted
   equivalent-mutant class already on record for `CleanUpOldMessagesJob`/`StockSummaryExportJob`.

   Submission full suite **6262/0/67**, +10 over the 6252 baseline.

   **Round 1 review complete** (`pr293-review-code.md` + `pr293-fact-check.md`): **1 High, 2 Medium,
   5 Low**. Fix commit `02208807`:

   - **H-1 fixed** (the load-bearing finding): `runForCurrentTenant()`'s FIRST submission silently
     dropped the activation-flag check, templated on `CleanUpOldMessagesJob.runForCurrentTenant()`,
     which also has none. This job's pre-D′ `doCalculation(Boolean)` ran both paths through the SAME
     activation-checking loop, so cloning the sibling's shape silently changed live behaviour: an
     admin's "run now" would have released picking orders for a tenant that explicitly deactivated
     the feature, with the javadoc actively asserting the opposite. Restored the check, corrected the
     javadoc, added `refusesWhenNotActivated` plus a matching `AdminTriggerTenantScopeUnitTest` pin.
     Two tests that had silently stopped exercising the activation-gated path (an artifact of the
     same mistake) now stub activation explicitly. **Round 2 (N-1) found this fix's OWN
     justification — "the sibling's missing check was a pre-existing quirk, not a D′ decision" — was
     itself false; see below.**
   - **M-2 fixed**: the idempotency argument's stated mechanism corrected — see above.
   - **M-1 fixed**: `runFor()`'s malformed-row `anyFailure = true` asymmetry (vs.
     `CleanUpOldMessagesJob`/`StaleClubBatchCleanupJob`'s `anyReadFailure`-only shape) was
     undocumented and untested — deleting the line survived the entire 6262-test suite. Added a
     comment explaining the divergence is deliberate (visibility into a permanently-skipped tenant)
     plus a test cloning `StaleClubBatchCleanupJobUnitTest.malformedRowCostsOnlyItself`.
   - **L-1/L-2/L-4/L-5 fixed**: wrong precedent citation for lock-busy metric silence (cited
     `StaleClubBatchCleanupJob`, which has zero `JobMetrics` calls of any kind, corrected to explain
     the real reason); missing asymmetry comment on the int4-overflow branch; a stale
     `AdminActionController` comment still naming `doCalculation(false)` as the current contract for
     a handler this PR converted; and a test that silently exercised the exception path instead of
     the success path its name/assertion claimed to cover (an H-1 side effect, fixed alongside it).

   The fact-check lane additionally caught the PR description's own file-count claim ("9 test files
   touched") was wrong — actual is 8, matching the file list already named beneath the wrong number.
   Fixed.

   Full suite after fixes **6264/0/67**, +2 over the submission baseline.
   `NeverMatcherNullBlindnessArchTest` census: **154→163** across 39 classes, +9 (corrected from an
   earlier miscount of 156/+7 in the PR description — both review lanes independently confirmed
   154/163/+9 by hand-summing the inventory; `AdminTriggerTenantScopeUnitTest` moved 2→4 and
   `ReleaseExpiredPickingOrdersFromUserJobTest` moved 2→9, both caught and fixed by the anti-drift
   test itself, working as designed).

   **Round 2 review complete** (`pr293-review2-code.md` + `pr293-fact-check2.md`, fresh worktrees at
   fix commit `02208807`): fact-check **7/7 PASS**, code review **1 High, 1 Medium, 2 Low (all new)**.
   Every round-1 finding independently re-verified as genuinely resolved. Fix commit `6d8e16b6`:

   - **N-1 fixed, and significant**: H-1's fix justified itself by claiming
     `CleanUpOldMessagesJob.runForCurrentTenant()`'s missing check was "a pre-existing quirk of that
     job, not a D′ decision." **False** — `git show e83d9550` (the commit before that job's own D′
     conversion) proves its manual path WAS activation-gated before conversion; the D′ conversion
     itself dropped the gate. **This means the identical H-1 defect is live on `develop` right now**,
     shipped via merged PR #291, undetected by two full review rounds on that PR. Corrected the false
     claim everywhere it appeared in this PR (javadoc, comments, test names). The live
     `CleanUpOldMessagesJob` bug itself is out of this PR's diff — already-merged, shipped code — so
     per this repo's ticket policy it was **proposed, not silently fixed**: raised directly with Nam
     and recorded above at the step 5 part 1 entry. Nam confirmed 2026-09-03: do a small follow-up PR.
   - **N-2 fixed**: `refusesWhenNotActivated` (round 1's H-1 regression test) didn't actually kill
     the mutant it exists to kill — deleting the guard left it green via an unrelated
     `NumberFormatException`, the identical L-5 failure mode reproduced inside L-5's own fix. Now
     stubs the timeout value and a non-empty order list so the guard's absence makes the release
     genuinely succeed; added the mirror case for the global cron kill switch.
   - **N-3/N-4 fixed**: the class javadoc now discloses the manual trigger touches NO per-tenant
     `JobMetrics` either, not just the whole-run gauges; a "lock-busy predicate" phrase colliding with
     the unrelated advisory-lock concept, and a self-contradictory `STRICT_STUBS`/lenient comment
     misattributing its own cause, both corrected.

   Full suite after round-2 fixes **6265/0/67**, +13 over the 6252 baseline. Two full independent
   review rounds clean, no open findings. **Merged into `develop` 2026-09-03 at `8c178ed1`, on
   Nam's explicit instruction ("merge #293").** PR: https://github.com/SiteBossInc/wms2-api/pull/293

   **Follow-up work spawned by this PR's review, tracked separately (not part of step 5 part 2):**
   a small PR against `develop` restoring `CleanUpOldMessagesJob.runForCurrentTenant()`'s activation
   check — Nam confirmed 2026-09-03 ("Do follow-up PR then"). See the ⚠ PROPOSED FINDING note at the
   step 5 part 1 (PR #291) entry above for full context. **PR #296, MERGED 2026-09-03 into
   `develop` at `bb264b87`** (branch `bugfix/SBDEV-3198-cleanupoldmessages-activation-gate`
   deleted), on Nam's explicit instruction ("Also merge #296"). Submitted at commit `7edd47d2`,
   based on fresh `origin/develop` (`56fc1035`). Restores the check, updates the javadoc to state
   the real history instead of the false "preserved behaviour" claim, fixes 5 tests that assumed
   the buggy behaviour, adds 2 new tests pinning the gate directly, hand-mutation-verified. Full
   suite **6265/0/67**. PIT 84% kill rate on `CleanUpOldMessagesJob`.

   **Round 1 review complete** (`pr296-review-code.md` + `pr296-fact-check.md`): fact-check **6/6
   PASS** (every claim independently re-derived, including the load-bearing `git show e83d9550`
   history check). Code review **0 High, 1 Medium, 3 Low**, all fixed in `7edd47d2`:
   - **M-1 fixed**: `refusesWhenGlobalCronSwitchOff` didn't kill its own mutant on its own
     assertion — deleting the global-switch clause died on a Mockito `PotentialStubbingProblem`
     (PR #293's N-2 failure class, reproduced in the test written to prevent it). Fixed with a
     `lenient()` stub on the short-circuited second key.
   - **L-1 fixed**: PR body's PIT explanation corrected from "try/finally duplication" to the
     actual mechanism (equivalent mutants — a true/false mutator pair where one side is always a
     no-op); the correction is favourable, return coverage is complete.
   - **L-2 fixed**: "Four existing tests" corrected to "Five" (the list already had 5 names).
   - **L-3 fixed**: not-activated refusal's log level DEBUG→INFO, matching `runFor()` and the
     pre-D′ behaviour — this method touches no `JobMetrics`, so the log line is the only
     observability this outcome has.

   Round 1's own sibling sweep independently confirmed the fix is correctly scoped to this job
   alone — `StockSummaryExportJob`'s activation-flag-free manual trigger is a genuinely different,
   correct shape (a separate ungated branch pre-D′), not the same bug.

   Full suite after fixes **6265/0/67**, unchanged (doc/log-level/test-only).

   **Round 2 review complete** (`pr296-review2-code.md` + `pr296-fact-check2.md`): code review
   **0 High, 0 Medium, 2 Low (both new)**, fact-check re-derived the round-2-specific deltas after a
   narrowed second pass (round 1's fact-check already covered the base claims). Fix commit
   `2ada3e37`:
   - **R2-L-1 fixed**: the not-activated refusal's INFO log line (L-3's fix) was — by the fix's own
     written justification — the ONLY observability that outcome has, yet nothing pinned it. Added
     a `ListAppender`-based log capture to `RunForCurrentTenantLocking`, mirroring
     `StaleClubBatchCleanupJobUnitTest`'s established pattern, asserting the refusal appears at
     `Level.INFO`. Hand-mutation-verified: reverting to DEBUG now fails the assertion.
   - **R2-L-2 fixed**: the PR description's own PIT-survivor paragraph cited line numbers the L-3
     fix had already shifted by the time the text was written. Dropped the line numbers in favor of
     citing the three return statements by role — this repo's own "cite a quoted string or a role,
     not a line number" discipline applied to itself. **Caught by round-2 fact-check that the first
     attempt at this text edit never actually landed on GitHub** (drafted locally, `gh pr edit` was
     not run) — republished and reconfirmed live on the PR before closing this out.

   Full suite after round-2 fixes **6265/0/67** (unchanged — a stronger assertion on an existing
   test, not a new one). Two full independent review rounds clean, no open findings. **Merged into
   `develop` 2026-09-03 at `bb264b87`, on Nam's explicit instruction ("Also merge #296").** PR:
   https://github.com/SiteBossInc/wms2-api/pull/296

   3/4. ✅ **MERGED — `OrderReleaseJob`.** This job is materially
   different from parts 1-2 in two ways, discovered 2026-09-03 before any code was written; flagged
   for confirmation rather than implemented solo, given this doc's own "orderRelease and replenish
   are the highest-frequency and most business-critical jobs" framing (line 949) and that this
   job's shape sets the template for the LAST remaining job, `ReplenishOrderJob`.

   **Nam's decision, 2026-09-03: "Go with B"** — the full grouped shape (option B below), not the
   minimal-change option A. Implemented in worktree `SBDEV-3198-STEP5-PART3`,
   branch `bugfix/SBDEV-3198-order-release`: `deriveSpecForCurrentTenant()`/`runFor(TriggerSpec)`/
   `runForCurrentTenant()` added to `OrderReleaseJob.java` (mirroring `CleanUpOldMessagesJob`'s
   template exactly, minus its dual-lock — see the idempotency verdict below, unchanged by this
   implementation pass); `doCalculation(Boolean)` deleted; `SchedulingConfiguration
   .configureOrderRelease()` replaced with `configureOrderReleaseGroups()`; `AdminActionController
   .triggerOrderReplenish` now calls `orderReleaseJob.runForCurrentTenant()` and surfaces its real
   outcome (`replenishJob`, step 5 part 4, is not yet converted, so the endpoint's returned boolean
   reflects only `orderReleaseJob`'s half until then — documented inline). Test surgery across
   `OrderReleaseJobTest`/`OrderReleaseJobUnitTest`/`OrderReleaseJobSectionGuardTest`/
   `OrderReleaseJobStreamingTest`/`OrderReleaseJobMetricsUnitTest`,
   `SchedulingConfigurationUnitTest`, `SchedulingReconcileIdempotencyUnitTest`,
   `AdminTriggerTenantScopeUnitTest`, `WholeRunSuccessGaugeUnitTest`, `AdminActionControllerUnitTest`
   and `NeverMatcherNullBlindnessArchTest`'s per-class `never()`-matcher inventory. Added a new
   `OrderReleaseJobUnitTest.RunForCurrentTenantLocking` nested class after PIT found ZERO coverage on
   every one of `runForCurrentTenant()`'s refusal paths beforehand (empty landlord row, int4
   overflow, lock-busy, not-activated, global-switch-off, release-threw) — same self-found-gap shape
   as `ReleaseExpiredPickingOrdersFromUserJobTest`'s equivalent class in step 5 part 2.

   Full suite **6291/0/0/67**, matching the known baseline. PR (not yet merged, awaiting Nam's
   explicit go-ahead): https://github.com/SiteBossInc/wms2-api/pull/301

   **Review round 1** (0 High, 3 Medium, 8 Low — all addressed): code-correctness lane independently
   re-derived the activation-check-provenance claim (read `e83d9550` directly), the no-dual-lock
   claim (read `ReleaseOrderJobService`'s `FOR UPDATE` + fresh state re-check directly, not the
   javadoc), business-logic byte-identity, and every trigger-count arithmetic claim — all confirmed.
   Findings: **M-1** `TriggerSpec`'s "NOT-YET-REACHABLE" zone-invariant-collapse label went false
   with this PR (on prd's current `*`/`*` config every tenant now collapses into ONE shared group,
   mechanically safe but a documentation gap) — fixed in both `TriggerSpec.java` and
   `configureOrderReleaseGroups`' javadoc; **M-2** the `skippedLockBusy` metric silently disappears
   for this job (family property of "no dual-lock", but undisclosed and one test's `@DisplayName`
   claimed a distinction its assertion couldn't support) — documented in the class javadoc, test
   narrowed; **M-3** `SchedulingConfiguration:290-303`'s "five NOT-YET-CONVERTED jobs" paragraph
   asserted the precise inverse of reality (five converted, one — `replenish` — not; pre-existing
   staleness from steps 4/5.1/5.2, not introduced by this PR) — corrected. Six Lows (stale
   `@DisplayName`s, a misleading test comment, an under-specific log assertion, a "six triggers"
   comment that was a floor not a count) fixed; two (a "run now can under-report while replenish
   succeeds" note, and an inherited `markLastSuccess()`-on-all-unreadable quirk shared by all five
   converted jobs) correctly left as documented-only per the reviewer's own disposition — fixing
   either solo would be inconsistent with the other four already-merged jobs. Fact-check lane
   independently confirmed all six of its own checked claims and found one more Low (a
   `@DisplayName` still saying "nine in all" where the assertion below it already said ten). Fix
   commit: `cad2267f`. Full reports:
   `sbdocs/1-Projects/wms2/plan/SBDEV-3198-evidence/pr301-review-code.md` and
   `pr301-fact-check.md`.

   **Review round 2** (0 High, 1 Medium, 5 Low — all addressed): re-verified all 11 round-1 findings
   were correctly fixed (9 fixed, 2 correctly left deferred exactly as instructed; zero
   touched-but-not-fixed, zero made worse; the one assertion edit strengthens rather than weakens).
   New finding: **N-1** the round-1 fix for M-3 corrected ONE stale "five" claim in
   `SchedulingConfiguration.java` but left two more in the SAME file (a "five still on
   `CRON_SCHEDULE_ZONE`" line and a "five single-trigger jobs" line, both actually two) — turning a
   uniformly-wrong file into a self-contradictory one. Fact-check lane independently re-measured the
   M-1 claim against LIVE data (not just re-citing an earlier measurement) via direct `psql`
   queries (MCP was down) confirming `ORDER_TIMER_HOUR`/`_MINUTE = *` on all five tenant DBs today,
   and mutation-verified the L-3 fix (flipped the pinned substring, confirmed exactly 1/43 tests
   failed, reverted). It found one more Low of the identical "five not-yet-converted jobs" drift in
   `TriggerSpec.java`'s own javadoc — same file M-1's own round-1 fix had already touched, missed on
   that pass. All fixed. Fix commit: `ee26ed79`. Full reports:
   `sbdocs/1-Projects/wms2/plan/SBDEV-3198-evidence/pr301-review2-code.md` and
   `pr301-review2-fact.md`.

   Full suite after both rounds' fixes: **6291/0/0/67** (unchanged both times — every fix was a
   comment/`@DisplayName`/one assertion-tightening change, zero `src/main` executable-line changes
   across either fix commit). Two full independent review rounds clean, no open findings.
   **Merged into `develop` 2026-09-03 at `6fdb6d25`, on Nam's explicit instruction ("merge the
   PR").** PR: https://github.com/SiteBossInc/wms2-api/pull/301

   **Idempotency verdict: step-3 (inert) shape, no dual-lock needed — and more strongly protected
   than any job converted so far.** `ReleaseOrderJobService.releaseOrder(orderId, ...)` calls
   `customerorderRepository.findByIdForUpdate(orderId)` — a pessimistic `SELECT ... FOR UPDATE` row
   lock, not merely `@Version` — then re-checks `order.getState() >= ASSIGNED` FRESH, inside that
   lock, before doing any work. A concurrent second call for the same order (old-code whole-fleet
   trigger racing a new-code per-tenant trigger during a rolling-deploy drain window) simply blocks
   on the row lock, then finds the order already advanced past `ASSIGNED` and no-ops. This is
   airtight independent of whatever advisory-lock scheme wraps it. The other write path,
   `releaseDueFutureTransferOrders()`, is a bulk CAS-style UPDATE self-selecting on
   `state = FUTURE_PICKING_DATE` — same self-excluding shape as step 5 part 2's job. No dual-lock
   mitigation needed for either write path.

   **But this job's REGISTRATION shape is neither part 2's (no schedule sysprop at all) nor the
   three grouped jobs' (each tenant derives its own spec) — it is a third shape.**
   `SchedulingConfiguration.configureOrderRelease()` reads
   `SYSTEM_PROPERTY_ORDER_TIMER_HOUR_KEY`/`MINUTE_KEY` — genuinely PER-TENANT-CONFIGURABLE sysprops,
   unlike part 2's hardcoded cron — but it does so ONCE, under whichever single tenant the boot
   probe (`TenantContext.setCurrentTenant(...)` around the whole registration pass, see
   `SchedulingConfiguration:380-424`) happened to land on, and registers ONE cron for the ENTIRE
   FLEET from that one tenant's value. `configureReplenish()` (step 5 part 4, not yet touched) does
   the identical thing with its own timer sysprops. So today, every tenant's `orderRelease` actually
   fires on whichever tenant the probe reached first — not its own configured hour/minute — and this
   is silent: nothing surfaces the mismatch if a tenant's own sysprop disagrees with the probe
   tenant's.

   **The design fork this creates — RESOLVED, "Go with B" (Nam, 2026-09-03):**
   - **(A) Minimal-change, matching part 2's philosophy:** keep the single fleet-wide registration
     exactly as-is (still sourced from whichever tenant the probe reaches), only tighten the
     per-tenant lock from job-wide one-key to per-tenant two-key inside the fire handler. Preserves
     today's live behaviour bit-for-bit, including the latent "probe tenant's schedule wins for
     everyone" quirk — which would then also need documenting rather than silently carrying forward
     un-disclosed, the same mistake this ticket's own reviews have twice found and fixed elsewhere.
   - **(B) Convert to the grouped shape**, deriving each tenant's own `TriggerSpec` from ITS OWN
     `ORDER_TIMER_HOUR/MINUTE_KEY` sysprops (mirroring `StaleClubBatchCleanupJob`/
     `StockSummaryExportJob`/`CleanUpOldMessagesJob`'s `deriveSpecForCurrentTenant()` pattern) — a
     genuine behavior IMPROVEMENT (each tenant finally honors its own configured release time) but
     larger in scope than "just convert the locking," and the same design decision would need making
     again identically for `ReplenishOrderJob` right after.

   Implemented per option B — see the summary above. This was exactly the shape of decision Nam
   confirmed for part 2 ("Go with A") before any code was written — flagged the same way rather
   than picking solo, given the stakes named above.

   4/4. ✅ **SHIPPED — `ReplenishOrderJob`, PR #304, the LAST of the six.** Submitted at
   `45586cfc`, **merged into `develop` 2026-09-03 23:19 at `24082277`** (branch
   `bugfix/SBDEV-3198-replenish-order`). PR: https://github.com/SiteBossInc/wms2-api/pull/304

   **The A-vs-B registration-shape fork — RESOLVED, "go with Option B" (Nam; recorded in the
   commit as 2026-09-04).** Exactly as this document predicted: `configureReplenish()` was
   byte-identical in shape to `orderRelease`'s pre-D′ `configureOrderRelease()`, reading
   `SYSTEM_PROPERTY_REPLENISHMENT_TIMER_HOUR_KEY`/`MINUTE_KEY` — genuinely per-tenant-configurable
   — under whichever single boot-probe tenant `TenantContext` landed on, then registering ONE
   fleet-wide cron from that one tenant's value. Option B converts it to the grouped shape, so each
   tenant finally fires on its own configured replenishment hour/minute.

   What shipped, per the commit:
   - `ReplenishOrderJob`: added `deriveSpecForCurrentTenant()` / `runFor(spec)` /
     `runForCurrentTenant()`, deleted `doCalculation(Boolean)`. The nine-method business logic was
     extracted **verbatim** into a private `replenish()` called identically from both entry points.
   - **The pre-existing JVM-wide `RUNNING` guard was deliberately kept** — unique among the six.
     Rationale recorded in the commit: this is the largest job body in the ticket (nine sequential
     paginated bulk operations per tenant) and `RUNNING` was always a resource throttle, not a
     correctness guard. Its scope is shared between `runFor()` and `runForCurrentTenant()`, matching
     pre-D′ exactly.
   - `SchedulingConfiguration`: `configureReplenish()` → `configureReplenishGroups()`;
     `configureAllTasks()` now reads **5 grouped + 1 single-trigger** job, and every job-count
     comment this conversion falsified was swept.
   - `AdminActionController.triggerOrderReplenish`: both `orderReleaseJob` and `replenishJob` now
     surface their real outcome via `runForCurrentTenant()`, returning
     `orderReleaseRan && replenishRan` — closing the placeholder-boolean caveat part 3 left open.
   - `TriggerSpec` and `ReleaseExpiredPickingOrdersFromUserJob` javadoc corrected, including one
     claim that directly contradicted `ReplenishOrderJob`'s own new class javadoc.
   - New `ReplenishOrderJobUnitTest` (ports `OrderReleaseJobUnitTest`'s `RunForCurrentTenantLocking`
     nested class — 6 tests — plus the JVM-busy refusal path no sibling has, two group-membership
     filter negative/read-failure paths, and one closing `runFor`'s per-tenant
     unlock/context-clear/metric gaps), plus test surgery across 12 more files, plus the
     `NeverMatcherNullBlindnessArchTest` census bumped to 194 sites across 40 classes (from 175/39).

   **Evidence, from the commit:** two independent review rounds, every finding addressed (2 High +
   5 Medium + 5 Low in round 1; 3 Medium + 5 Low + 2 Info in round 2 — all claim-accuracy, no
   production defect in either round). Both round-1 Highs were coverage gaps found by review, not
   by the suite: `runForCurrentTenant`'s refusal ladder had zero coverage, and `RUNNING.set(false)`
   plus both `unlock` calls were surviving removal mutants. PIT scoped to the wrapper this PR wrote:
   **0 `NO_COVERAGE` (was 12), test strength 78% (was 74% pre-fix)**, matching or exceeding the
   merged `OrderReleaseJob` template's 74%/85% split. **Full suite 6305/0/0/67, matching baseline**
   (+11 new tests, 0 regressions).

   The idempotency audit recorded above (all nine write methods protected — eight by per-row
   `OptimisticLockException` catch, `mergePickingOrders` failing safe by aborting the whole tenant
   cycle, and the two maintenance-service calls on a pessimistic `SELECT … FOR UPDATE`) held up
   through implementation: **no dual-lock mitigation was needed**, and none was added.

6. ✅ **DONE — `SchedulingConfigurationUnitTest` was rewritten, not deleted.** It stood at 33
   `@Test` when this was written and is **43 on `develop`** today, still carrying its arity pins
   (`All 6 scheduled tasks configured`, `Only 1/6`, `Only 0/6`, `Only 5/6`,
   `eachTriggerIsWiredToItsOwnJob`) — retargeted at the new **5 grouped + 1 single-trigger** shape
   rather than dropped to make a build go green. `SchedulingReconcileIdempotencyUnitTest` and
   `TriggerSpecUnitTest` were added alongside it.

Both smaller cleanups landed rather than being scheduled separately — **both ✅ DONE**:

- ✅ **`NeverMatcherNullBlindnessArchTest`'s per-file `never()`-site census** was re-measured in
  each converting PR, ending at **194 sites across 40 classes** (from 175/39) in PR #304.
- ✅ **The stale `src/main` javadoc/log sites, including the operator-facing one.**
  `git grep "Slice B" origin/develop -- src/main` now returns **zero hits** — the
  `SchedulingConfiguration` javadoc that read *"That is SBDEV-3191 Slice B"* was corrected by the
  PRs that touched the file, exactly as prescribed, with no commit of its own. Each part's own
  review round swept the javadoc claims its conversion falsified (part 4 fixed two, one of which
  contradicted `ReplenishOrderJob`'s own new class javadoc).

Note also, from the enumeration: **`*IT.java` is a true empty bucket here** — zero of the 28 `*IT`
classes reference the six jobs or the `schedulejob` package. That was positive-controlled (the same
scan matched `SpringBootTest|@Test` in 28/28), so it is a real zero rather than a broken grep, and
the usual "exists but runs in neither maven lane" caveat does not apply to this ticket.

---

## 8. What this document deliberately did not do — and what overtook it

> ⚠ **Superseded 2026-09-06.** This section described the document's scope *at rev 2*, before any
> code existed. It is retained for provenance; the paragraph below it is no longer true of the
> ticket, only of the document as first written. All six jobs shipped between 2026-09-02 and
> 2026-09-03 across seven PRs (#278, #279, #283, #286/#287, #288, #291/#296, #293, #301, #304) —
> see §7a for the per-part record, which is the authoritative sequencing state.

No code, no failing tests, no worktree, no branch. Slice A's lesson was that the expensive part of
this ticket is the design, not the implementation: the originally prescribed fix would have shipped
a regression, and two of the three reasons why were invisible until someone read the jobs and the
pool configuration. The next step is a decision on §4 and §6, not a TDD gate.

---

## 9. Closing state (2026-09-06)

**Code: complete and deployed to dev.** `GET https://wms-api.dev.sbo.li/api/public/version` returns
`{"environment":"DEV","self":{"repository":"wms2-api","version":"develop-d4a6ab8a…"},"drift":false}`,
and `d4a6ab8a` sits downstream of `24082277` (PR #304, the last 3198 merge). Only one unrelated
commit — `d4a6ab8a` / SBDEV-3226 — has landed on `develop` since.

**Acceptance criteria — what the merged code and tests actually establish.** Test pins were located
by scoping the AC grep to the 43 `src/main` + `src/test` files that cite `SBDEV-3198`, not by a
bare `AC\d+` sweep (other tickets number their ACs the same way and contaminate the count):

| AC | State | Evidence |
|---|---|---|
| AC1 — each tenant's own `*_TIMER_*` | 🟡 **code merged, pinned in unit tests; UAT boot-log check outstanding** | `SchedulingConfiguration`, `SchedulingConfigurationUnitTest`, `SchedulingReconcileIdempotencyUnitTest`, `StaleClubBatchCleanupJobUnitTest` |
| AC2 — each tenant's own IANA zone | 🟡 same — Hydra firing 03:00 **New York** still needs the deployed log | same files |
| AC2′ — scope + UTC-fallback named in provenance | ✅ | `SchedulingConfiguration`, `StaleClubBatchCleanupJob`, `SchedulingConfigurationUnitTest` |
| AC3 — no double execution per tenant | ✅ | `SchedulingConfigurationUnitTest`, `StaleClubBatchCleanupJobUnitTest` |
| AC4 — co-firing groups all process | ✅ | `SchedulingConfigurationUnitTest`, `ReleaseExpiredPickingOrdersFromUserJob` |
| AC5 — mixed-version lock-space hazard | 🟡 **blocked on Portainer** — one `app.cron=true` container must be *confirmed*, not assumed |  |
| AC5a — `100007L`/`100008L` stay one-key | ✅ | `AdvisoryLockServicePerTenantLockUnitTest` |
| AC6 — the five untagged whole-run metrics | ✅ | `WholeRunSuccessGaugeUnitTest` + the per-job `*MetricsUnitTest` files, each rewritten off its single-tenant fixture |
| AC7 — landlord pool not exhaustible | 🟡 **risk accepted (Nam, 2026-09-03)** as a non-blocker; the measured cap is still unstated |  |
| AC8 — PIT per changed class | ✅ | run in every part; part 4 ended at 0 `NO_COVERAGE` (was 12), 78% strength |
| AC9 — full suite vs fresh baseline | ✅ | measured per PR; #304 recorded **6305/0/0/67**, +11 tests, 0 regressions |
| AC10 — boot-time reachability | ✅ | PR #283's converging additive-only registration; `SchedulingReconcileIdempotencyUnitTest` |
| AC11 — activation/deactivation both directions | ✅ | `SchedulingConfigurationUnitTest`, `StaleClubBatchCleanupJobUnitTest` |
| AC12 — no group-membership component in the lock key | ✅ | `AdvisoryLockService`, `StaleClubBatchCleanupJobUnitTest` |
| AC13 — admin trigger endpoints gated + tenant-correct | 🟡 **(a) met for 1 of 2 endpoints** — see below; (b) and (c) ✅ | PR #278 (gate on `:191`), #279 (caller's tenant), #304 (real outcome for both `triggerOrderReplenish` jobs); `AdminTriggerTenantScopeUnitTest`, `AdminActionConsoleGateUnitTest` |

> ### ⚠ Found 2026-09-06, after the ticket was marked `on dev` — AC13(a) is half-met
>
> `AdminActionController` has 9 handlers. **8 are gated; `triggerUpdateStock:122` carries no
> annotation at all** (measured on `origin/develop` @ `d4a6ab8a`, the build running on dev, by
> walking every `@(Get|Post)Mapping` against its preceding annotation line).
>
> AC13(a) reads *"the two ungated endpoints carry an authorization annotation."* PR #278 gated
> `triggerReleaseExpiredPickingOrdersFromUser:191`. `triggerUpdateStock` — the other endpoint this
> plan's own §3 table flagged `🚨 NONE` — was never annotated, and unlike every deliberate carve-out
> on this class there is **no comment above `:122`** recording a decision to leave it open.
>
> **Unannotated is open here, not closed.** The class is absent from `FunctionGuardInterceptor.GUARDED`
> (verified, zero hits), so an unannotated handler takes the interceptor's `return true` branch rather
> than being denied by default; `/v3/adminAction/**` maps to `hasAnyAuthority(wms_user)` and
> `super-admin` is enforced solely via `@RequiresFunction`. Any `wms_user` reaches it.
>
> **Blast radius, stated precisely:** it fires `stockSummaryExportJob.runForCurrentTenant()` — a
> full-inventory OMS export for the **caller's own** tenant (AC13(b)/#279 removed the fleet-wide
> scope), throttled by the per-tenant two-key advisory lock. An unauthorized *trigger* and out-of-band
> export load; **not** a cross-tenant read, and not data exposure.
>
> **How nine PRs and eighteen review rounds missed it:** every lane checked the code that was written.
> None re-derived the AC against the whole class. The AC named a count ("the two ungated endpoints")
> and the work satisfied it for the endpoint that had its own PR title. This is the
> `advertised-capability ≠ measured-capability` failure in a new costume — and the reason the fix is
> cheap (one annotation line, on the function every sibling already uses, no new `FunctionEnum`
> constant / `mywms_function` row / grant line / migration) is exactly why it was easy to assume done.
>
> Recorded in `3-Resources/architecture/wms2-keycloak-role-matrix.md` §8.y. **RESOLVED 2026-09-06:
> Nam's instruction was to file it — tracked as SBDEV-3243** (High, T1,
> https://app.clickup.com/t/868m2402d), a new ticket rather than reopened scope, since this ticket is
> already `on dev`. AC13 here stays 🟡 until 3243 lands.
>
> One fact found while writing 3243 up that was not known when this box was first written, and it
> moves the risk in both directions: **the endpoint is UI-called, not an orphan** — `wms2-web-ui`'s
> "Manual Full Stock Update" button on Admin > System Management fires it (`actions.vue` →
> `actionConfirmation.vue:68` → `store/admin/mgmt/action.js:27`). Worse, because it is a live
> operator button any `wms_user` can reach; better, because `pages/admin.vue:56` gates that tab on
> the **same** `WEB_UI_VIEW_IMPORT_DATA`, so there is **no operator-lockout risk** — the trap AC13
> itself warned about. Note also that 3243 carries an AC the annotation alone cannot satisfy:
> whether `AdminActionController` should join `FunctionGuardInterceptor.GUARDED` so the *next*
> unannotated handler fails closed. The annotation is the instance fix; GUARDED membership is the
> invariant one.

**Three things no probe can close** — they need a named owner, not another run:

1. **The two Portainer facts** (AC5, AC7): the running `LandlordHikariPool` cap, and whether exactly
   one container carries `app.cron=true`. Both were prerequisites from the start; the work shipped
   without them because AC7's risk was explicitly accepted and AC5's hazard is unexposed under
   recreate deploys *provided* the singleton holds.
2. **AC1/AC2 on UAT.** The whole point of the ticket is a behaviour only observable across ≥2
   tenants, and UAT is the only environment with four. Slice A's provenance logging is what makes
   this readable from a boot log — that was its stated purpose. Dev has one active tenant and cannot
   discriminate.
3. **Leftover worktrees removed 2026-09-06**: `SBDEV-3198`, `-STEP4`, `-STEP5-PART3`, `-STEP5-PART4`
   under `.claude/worktrees/wms2-api/`, all clean and all merged.
