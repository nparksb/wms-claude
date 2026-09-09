---
title: "Audit — WMS v2 multi-tenancy readiness for onboarding WineCo and ShipItEZ to production"
type: report
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-09-01
updated: 2026-09-01
status: "COMPLETE for lanes A/B/C + own verification. Lane D's code-side onboarding pass was still in flight at write time; its docs-side subreport is folded in. VERDICT: DB-multiplexing is structurally sound and already rehearsed on UAT, but FOUR blockers must land before a prd cutover — three are invisible at one tenant by construction."
db_verified: true
db_verified_rationale: "Measured live 2026-09-01 against landlord-prd, landlord-uat, wms2-hydra (prd), wsl-wineco-uat, nywh-shipitez-uat, c1wh-shipitez-uat. Nirvana id divergence, FK existence, sysprop timer divergence, connection census, Flyway versions and the shared Keycloak service credential are all DB-measured, not inferred."
related:
  - ../architecture/wms2-tenant-routing-datasource-topology.md
  - ../architecture/wms2-scheduled-jobs-catalog.md
  - ../architecture/wms2-caching-strategy.md
  - ../architecture/wms-database-migration-guide.md
tags: [report, multi-tenancy, datasource, onboarding, wms2]
---

# WMS v2 multi-tenancy readiness — WineCo + ShipItEZ onto production

**Question asked:** what needs improving in the DB-multiplexing multi-tenancy before WineCo and
ShipItEZ join Hydra on v2 production in a few weeks.

**Verdict.** The routing mechanism itself is sound and is **already running the target shape on
UAT**. The risk is not in the datasource layer. It is in **four places where per-tenant state was
put on a process-wide singleton** — code that is correct-by-accident while exactly one tenant
exists, and becomes wrong on the first request after a second tenant is added. Three of the four
blockers below are of that class. None of them can be found by testing with one tenant, which is
why they have survived.

---

## 1. Baseline — measured 2026-09-01

### 1.1 The transition

| | prd today | prd after cutover | UAT today |
|---|---|---|---|
| Tenants | 1 (`hydra`) | 3 | 3 |
| Tenant-**facilities** (routing keys) | **1** — `hydr-nywh` | **4** | **4** |
| Landlord rows | 1/1/1/1 | 4 db_config, 4 discovery, 3 auth | 4 / 4 / 3 |

**The 1→4 fan-out is already rehearsed.** UAT runs `hydra/nywh`, `shipitez/c1wh`, `shipitez/nywh`
and `wineco/wsl` against one landlord, all at Flyway **V2.2.23** (migrated 2026-09-01 14:48). UAT's
landlord rows are a working template for the prd ones. This materially de-risks the structural
work and is the single most useful asset going in.

### 1.2 Branch reality — CORRECTED TWICE, final

> This section was wrong twice. First it said prd runs `main` @ `cf430ff3`, "296 commits behind
> `develop`". Then it was "corrected" to say prd tracks `release`, not `main`. **The second
> correction was also wrong**, and the way it went wrong is itself the finding.

**Prd tracks `main`.** The promotion flow is `develop` → `release` → `main`, exactly as the Flyway
runbook always said.

**The real hazard: `origin/main` HEAD and the running production image drift in BOTH directions,
within a single day.** Measured 2026-09-01, both readings hours apart in the same session:

| Time | prd running (`/api/public/version`) | `origin/main` HEAD | |
|---|---|---|---|
| ~15:00 | wms2-api **0.0.21** (tops at V2.2.21) | v0.0.17 (V2.2.16) | main **BEHIND** prd by 5 migrations |
| ~16:30 | wms2-api **0.0.21** (unchanged) | v0.0.22 (V2.2.23) | main **AHEAD** of prd |

`main` lagged because the promotion merge had not run yet; two hours later it led because the deploy
had not run yet. Both are normal mid-cycle states. Reading the 15:00 snapshot as evidence about the
*branching model* — rather than about *timing* — produced the false second correction.

**Practical consequences for the cutover, all of which survive the correction:**

1. **The authz programme IS live on prd.** `FunctionGuardInterceptor` is in the v0.0.21 build prd is
   running (release commit `46212c30`, now an ancestor of `main`). WineCo and ShipItEZ users will be
   **function-gated from first login, with no grace period**. Any note saying the programme is
   develop-only is stale.
2. **Never infer prd's state from a branch HEAD.** Read `/api/public/version` and pin to the matching
   tag. This is load-bearing for `apply-pending-tenant-flyway.sh --env prd`, whose pending set comes
   from the checkout's migration files: a checkout that leads over-reports (safe, noisy); one that
   lags **under**-reports silently — the state that actually existed at 15:00.
3. **Delivery path (Nam, 2026-09-01):** fixes target **`develop`**, which is merged to **`release`**
   to build the UAT and PRD containers. So the deadline for Tracks 1 and 2 is **the release cut that
   builds the cutover container**, not the cutover date.

All four §2 blockers were derived from `origin/develop` and are present on `release` and `main` —
i.e. live in production today.

### 1.3 Connection topology — one instance, not many

prd is **one PostgreSQL instance**, all databases as backends of it:

| Database | Conns | Active <5m |
|---|---:|---:|
| `wms2_landlord` | **23** | **21** |
| `wh01_om1` (v1 WineCo) | 13 | 0 |
| `wh01_hydra_v2` (v2, live) | 7 | 0 |
| `wh01_shipitez` / `wh02_shipitez` (v1) | 3 / 3 | 0 |
| `keycloak`, `keycloak2`, `postgres` | 5 total | 0 |

`max_connections = 300`, 61 in use. Two consequences: the binding limit is the **aggregate**, shared
with live v1 traffic, and there is **no per-database `CONNECTION LIMIT`** — one tenant can consume
the whole 300. Capacity is not the constraint at these numbers, but the isolation story is weaker
than "a database per tenant" suggests.

`autovacuum on`; `statement_timeout 0`; `idle_in_transaction_session_timeout 0`.

### 1.4 Facts that are NOT problems (checked, cleared)

- **Hydra prd is no longer stuck at V2.2.06** on the object-ownership problem. It migrated cleanly
  through V2.2.21 on 2026-08-26. Prior notes saying otherwise are stale.
- **prd's schema matches its running code.** Both top out at **V2.2.21** (image v0.0.21). An earlier
  draft reported the DB as "five versions ahead of the app" — that came from comparing against
  `origin/main` at a moment when main lagged the deploy (§1.2), not from a real divergence.
- **prd's Flyway history is non-monotonic, and that is by design.** `installed_rank` 16 = V2.2.16
  (2026-08-17), rank 17 = **V2.2.11** (2026-08-26) — a lower version applied later. This is
  `app.flyway.out-of-order=true` working as intended (the repo merges migrations in review order, not
  version order). Worth knowing when reading the table; not a defect.
- **The 2026-08-26 migrations were applied by a boot-time batch, not by hand** — all six landed
  within the same second (15:26:43), which is the `StartupFlywayMigrator` signature.
- **ShipItEZ's two timezones are safe** because its two warehouses are two separate databases, each
  with its own pool and its own `connectionInitSql` session zone. Preserve that property — a single
  shared DB for both warehouses would break it.
- **prd's `UNIQUE (warehouse)` / `UNIQUE (realm)` landlord constraints are confirmed dropped** — the
  constraints that would have made a two-warehouse client impossible.

---

## 2. Blockers — land before the cutover

### B1 · CRITICAL · Two singletons memoize one tenant's "nirvana" rows process-wide

`service/UnitloadBusinessService.java:106-133` and `service/StockunitBusinessService.java:87-112`
each hold `nirvanaUnitload` (+ `nirvanaLocation` in the first) and a single `boolean initialized`
as **instance fields on a `@Service` singleton**. `@PostConstruct` always returns early at boot (no
tenant context), so the **first request from any tenant** populates the fields and flips
`initialized` — permanently, for every tenant. `ensureInitialized()` only re-runs while
`!initialized`.

The write is `StockunitBusinessService:422` — `stockUnit.setUnitloadId(nirvanaUnitload.getId())`.

**The ids genuinely differ** (measured):

| Facility | Nirwana unitload id | unitload id range |
|---|---:|---|
| hydra/nywh (prd) | **1** | … 150,646 |
| shipitez/nywh | **1** | — |
| shipitez/c1wh | **5,069,679** | 2,407,187 … 119,940,529 |
| wineco/wsl | **66,252** | 66,250 … 988,306,635 |

WineCo's high, offset id space is the v1→v2 dual-island `seqentities` signature.

**Failure mode — corrected from the lane report.** The lane concluded this writes silently because
"manual FK Longs only, nothing rejects it." That is wrong at the database level. The constraint
exists:

```
fkhoxjsrvueohjwo8qjyi6falad  FOREIGN KEY (unitload_id) REFERENCES unitload(id)
```

JPA does not model the association; **PostgreSQL enforces it**. So:

- **Today: a loud FK violation.** Every cross-tenant borrow lands on a non-existent id (id 1 is
  below WineCo's minimum of 66,250; 66,252 is a permanent gap below Hydra's max; 5,069,679 exists
  in neither). The discard-to-nirvana workflow simply **breaks for every tenant except whichever
  made the first request after the deploy** — non-deterministic across restarts.
- **Silent corruption is reachable later**, because the ranges *overlap* (WineCo 66,250–988M vs
  c1wh 2.4M–120M). A borrowed id that happens to exist in the target tenant passes the FK and moves
  stock onto a real, possibly pickable unit load.

**Mitigating:** the `nirvanaLocation` half is benign — location id is **0 in all four** facilities,
so `UnitloadBusinessService:424` is correct by coincidence. Only the unitload half bites.

*Present on `main` as well as `develop`.* → **Remediation:** make the lookup per-tenant (resolve on
each call, or key a map on the tenant key); delete the `initialized` latch.

### B2 · CRITICAL · The cron schedule for *all* tenants is read from *one arbitrary* tenant's DB

`schedulejob/SchedulingConfiguration.java:107-113`:

```java
Map<String, TenantDbConfiguration> all = dbConfigCache.getAll();
TenantDbConfiguration dbConfig = dbConfigCache.get(all.keySet().iterator().next());
TenantContext.setCurrentTenant(new TenantProfile(...));
try { configureAllTasks(scheduler); } finally { TenantContext.clear(); }
```

`configureAllTasks` builds **one** `CronTrigger` per job for the whole process, and each
`configureX` reads its `*_TIMER_HOUR`/`_MINUTE` via `syspropService.getSysvalue(...)` under that
single tenant's context. `los_sysprop` lives in the **tenant** DB, so the schedule every tenant runs
on is whichever tenant `iterator().next()` yields.

**The values diverge** (measured):

| Sysprop | Hydra (prd) | WineCo (uat) |
|---|---|---|
| `STOCK_SUMMARY_EXPORT_TIMER_HOUR` | **3** | **17** |
| `..._SPLIT_AMOUNT_SKU_PER_BATCH` | 250 | 150 |
| `ORDER_TIMER_HOUR` / `_MINUTE` | `*` / `*` | `*` / `*` |

Onboard WineCo and Hydra's nightly full-inventory export to OMS can silently move from hour 3 to
hour 17 — mid-shift — with no code change, no Hydra-side config change, and no log naming whose
schedule was used.

**Correction to the lane report:** it computed the `ConcurrentHashMap` bucket order and asserted the
winner flips from `hydr-nywh` to `wine-wsl`. Do not rely on that. `getAll()` returns a **freshly
constructed** `ConcurrentHashMap` copy per call (`TenantDbConfigCache.java:41-43`), so ordering
depends on that copy's table sizing. The dependable statement is the **invariant**: the winner is
arbitrary and *changes when the tenant set changes*. Read it off a boot log; do not predict it.

*Present on `main`.* → **Remediation:** move timer syspropse to the landlord DB (they are
process-global by construction), or register a per-tenant `CronTrigger`. Either way, log which
tenant supplied the schedule — the absence of that line is why this would ship silently.

### B3 · CRITICAL · Keycloak user cache is keyed on bare username

`service/KeycloakService.java:61` — `Cache<String, UserRepresentation>` on a singleton, while the
realm is resolved **per request** (`getCurrentRealm()`, `:95/:104/:123`). All 12 get/put/invalidate
sites key on `username` alone.

A username present in two realms returns the wrong tenant's Keycloak UUID, email, name and **group
paths**. Not hypothetical — `panderson` exists in both the hydra and wineco directories, and
SiteBoss staff accounts span realms by design. It also makes `resetUserPassword`,
`checkIsWarehouseUser` and `userExistsInKeycloak` answer from the wrong realm. Note ShipItEZ's two
warehouses legitimately share one realm, so the collision axis is tenant/realm (3-way), not
facility (4-way).

→ **Remediation:** key the cache on `realm + ":" + username`.

### B4 · HIGH · The only fast-cutover path breaks on a duplicate warehouse code

`TenantDbConfigurationRepository:16` declares `Optional<TenantDbConfiguration> findByWarehouse(String)`.
The real constraint is `(warehouse, tenant_id)` — and **UAT already has two `nywh` rows** (hydra and
shipitez). Two rows into an `Optional` is `IncorrectResultSizeDataAccessException`.

Blast radius, traced:

- **Live: exactly one call site** — `controller/actuator/TenantPoolEndpoint.java:45`.
  `/actuator/tenantpool` is the **only** push-refresh path (the topology doc's "no push mechanism"
  is stale). It 500s for `facility=nywh` — which is **Hydra, the live tenant**, as well as ShipItEZ
  NY. The tool you would reach for to make a new tenant routable without waiting 5 minutes is the
  tool that breaks first.
- **Dead but landmined: three more.** `LandlordService:73`, `TenantRoutingService:35` and
  `TenantAuthConfigurationRepository:19` have **zero callers** in `src/main`. Notably
  `TenantRoutingService.getWarehouseDataSourceMap()` does `Collectors.toMap(getWarehouse, getDbUrl)`
  — `IllegalStateException: Duplicate key` on two `nywh` rows — and its javadoc reads *"Useful for
  pre-loading the AbstractRoutingDataSource at startup"*, precisely the helper someone would wire up
  during this onboarding work.

**Cleared:** the auth path is unaffected — `TenantAuthConfigCache` is populated via `findByTenantId`.

→ **Remediation:** key on `(warehouse, tenantId)` at all four sites; delete the three dead ones.

### B5 · CRITICAL · Both provisioning docs tell the operator the opposite of what the app does

`wms2-greenfield-db-provisioning.md:92` — *"`flyway-core` is `<scope>test</scope>` … **Flyway never
runs in production**, and there is no `flyway_schema_history` on production tenant DBs (all migration
is manual `psql`)"*.

`wms2-database-setup-guide.md:31` — *"**Foundational fact** … the v2 app **does not run Flyway at
runtime** — migrations are applied manually by an operator."*

**Both are false on `main`, `release` and `develop`.** `app.flyway.migrate-on-startup=true`;
`flyway-core` is runtime scope (the pom comment reads *"Runtime scope (was test)"*); and prd's own
history shows a boot-time batch of six migrations landing within one second on 2026-08-26.

These are the two documents an operator would follow to provision WineCo and ShipItEZ. Following them
produces a **populated schema with no `flyway_schema_history`**, which lands in the
`skippedNoHistory` branch of `StartupFlywayMigrator` (`:310-322`): the tenant is skipped **every
boot, forever**, and never receives another schema change.

**Correction to the lane report on the failure's visibility.** The lane called this "green boot, no
alert." That is only half right, and the half it gets wrong matters. The branch:

- logs at **`log.error`** with the exact repair (`db/backfill-flyway-history.sh --dbname <db>
  --owner <tenant role> --up-to <watermark>`, with the tenant's own role interpolated),
- increments `skippedNoHistory` **and** `staleTenants`,
- publishes a per-tenant staleness gauge via `recordAll(labels, false, false)`.

So it is detected, named and metered. What *is* true is that **the boot stays green** — deliberately,
so a transient landlord outage cannot take down every tenant. The signal therefore lives entirely in
an ERROR line and a gauge. Whether anything consumes that gauge is **unverified** (§7 Q2). This is
precisely how `wh01_hydra_v2` sat nine migrations behind for twelve days in August — the code comment
at `:325-328` says so in as many words.

→ **Remediation:** correct both docs before anyone provisions from them; confirm the staleness gauges
are scraped and alerted.

---

## 3. High — fix before or immediately after cutover

### H1 · One tenant's DB down at boot kills scheduling for every tenant, silently

`SchedulingConfiguration.isTenantDatabaseInitialized()` (`:145-163`) probes only the **same** first
key as B2. If it never connects, the `while (attempts < 60)` loop at `:103-128` exhausts and falls
through **with no log line at all** — six of eight jobs are never registered for the life of the
process. The empty-cache path logs an error; the attempts-exhausted path logs nothing. The two
`@Scheduled` jobs survive, so outbox traffic keeps flowing while order release is dead — which makes
it look like a data problem, not a scheduling one.

### H2 · Landlord pool of 2 against 10 schedulable tasks, and exhaustion is misreported

`AdvisoryLockService.tryLock` pins a landlord connection for the **entire** job body (`:56-80`), and
each job needs a second for `findByActiveTrue()` — one job can occupy both. Job bodies are
`for (tenant : tenants)`, so pin duration is **linear in tenant count**. The code says it:
`OutboxDispatcherJob.java:67-69` documents a worst-case pin of `N × 15s` — **15 s → 60 s at N=4, on
a job that fires every 15 s**. All four tenants carry `ORDER_TIMER=*/*` and `REPLENISHMENT_TIMER=*/*`,
so three heavy jobs sweep every tenant every minute.

Worse, the failure is **silent and misattributed**: `tryLock` catches `SQLException` at `:76-79` and
returns `false`, which the caller logs as *"already running on another replica"*. A landlord outage
is indistinguishable from healthy lock contention.

**Replica count — ANSWERED (Nam, 2026-09-01): starting at 1, scaling to 2, maximum 3.**

That makes the projections falsifiable. At the 3-replica ceiling with 4 tenant-facilities:

| | today (1 tenant, 1 replica) | after cutover, worst case (4 facilities, 3 replicas) |
|---|---:|---:|
| Tenant pools | 1 × 5 = **5** | 3 × 4 × 5–10 = **60–120** |
| Landlord pool | 1 × 2 = **2** | 3 × 2 = **6** |

Against `max_connections = 300` shared with live v1 traffic (61 in use today), **capacity is not the
binding constraint** — even the 120 case leaves headroom. Two caveats survive:

- **The per-tenant `maxPoolSize` is the lever, and it is per-row in the landlord.** UAT already sets
  wineco to 10 while the others are 6. Four facilities × 10 × 3 replicas = 120; keep an eye on the
  sum rather than any single row.
- **The landlord arithmetic still does not reconcile.** 1 replica × cap 2 = 2 expected, but prd
  shows **23 connections, 21 active within 5 minutes**. So either the cap is overridden in Portainer,
  or something other than wms2-api replicas is connecting to `wms2_landlord`. Worth identifying before
  cutover — at 3 replicas and 8 cron jobs the landlord pool is the contended resource (H2 above), and
  a wrong model of who holds those 23 makes it unsizeable.

### H3 · Cron firing zone is hard-coded to LA while tenants span two coasts

`SchedulingConfiguration.java:38` — `CRON_SCHEDULE_ZONE = TimeZone.getTimeZone("America/Los_Angeles")`.
The comment above it already concedes the problem: *"Any future job whose EFFECT must occur at a
tenant's local midnight needs per-tenant scheduling, not this single server-level zone."*
Hydra = `America/New_York`; wineco/wsl and shipitez/c1wh = `America/Los_Angeles`; shipitez/nywh =
`America/New_York`. **With one shared trigger this is unsolvable by configuration at four tenants.**
Fixing B2 with per-tenant triggers dissolves this too.

### H4 · No per-tenant pool metrics — every other finding becomes undiagnosable

Zero `MetricsTrackerFactory` in `src/main`; tenant pools are not Spring beans, so Boot never binds
Micrometer to them. At one tenant you infer saturation from latency. At four you cannot tell *which*
tenant is saturating, and `hikaricp.connections.pending` does not exist.

### H5 · BOL close-guard is a process-wide id set

`service/BillofladingService.java:162` — `private final Set<Long> bolToClose = ConcurrentHashMap.newKeySet()`,
added at `:302`, removed at `:750`. BOL ids are per-tenant sequences, so Hydra closing BOL 1234 makes
ShipItEZ's BOL 1234 fail with *"BOL is currently in process."*, and whichever finishes first drops
the other's guard.

### H6 · Shared Keycloak service credential, across tenants *and* environments

The `idm-admin` service password in `tenant_auth_configuration` is **identical across all three UAT
realms**, and **prd hydra's value is byte-identical to UAT's** (compared by hash; value not
reproduced here). One credential compromise = Keycloak admin on prd Hydra *and* all three UAT
realms. If prd WineCo/ShipItEZ rows are provisioned by copying the UAT rows — the natural move — that
extends to three prd realms. Same shape as the known OMS-credential finding (SBDEV-3181), and it
gets worse at exactly the moment you onboard.

### H8 · Landlord DB password is a cleartext literal in the build running production

`landlord.datasource.password=wmsLandlord@sb` is a committed literal on **`main` and `release`** —
i.e. in the build prd is running now. Only `develop` has `${LANDLORD_DATASOURCE_PASSWORD}`. SBDEV-3175
is therefore **half-fixed**: the fix exists but has not reached the branch production deploys from.

Blast radius scales exactly with this cutover. That one string currently yields one tenant's DB
credentials; after onboarding it yields **four production DB credential sets plus three realms'
client secrets and `idm-admin` service passwords** (all plaintext in `tenant_auth_configuration`).
Committed 2025-12-28, never rotated.

### H9 · Onboarding is entirely manual SQL, with no tooling and no Keycloak checklist

Ten landlord rows are required per new tenant-facility and **no tool creates any of them** —
`LandlordService.createTenant` has no controller. Separately, **no per-tenant Keycloak provisioning
checklist exists anywhere in the vault, and there are zero ShipItEZ Keycloak docs**. For a
few-weeks timeline across three facilities, the absence of a written, reviewed sequence is itself the
risk — B5 shows what happens when the only written guidance is wrong.

### H7 · Landlord starvation is a cross-tenant outage

`/api/public/authConfig` — the login page — reads the landlord DB live and uncached
(`TenantDiscoveryController.java:24-31`). Tenant pools are properly isolated and virtual threads keep
a blocked request off the Tomcat pool, but the **landlord pool and the shared PG instance have no
isolation at all**. Landlord saturation logs out everyone, for every tenant, at once.

---

## 4. Medium

| # | Finding | Detail |
|---|---|---|
| M1 | No lock timeout anywhere | `jakarta.persistence.lock.timeout=5000` is **inert** on PostgreSQL — `PostgreSQLDialect.supportsWait()` returns false (hibernate-core 6.6.39.Final:1391). Lock waits hold pool slots indefinitely. |
| M2 | No `socketTimeout` on any `db_url` | A stalled tenant DB hangs pool creation forever **inside a `computeIfAbsent` bin lock** — so it can block other keys hashing to the same bin. |
| M3 | 26 `allEntries`/`cache.clear()` sites | Couple all four tenants' caches: one tenant's write flushes everyone's. |
| M4 | Caffeine `maximumSize` values are global | Per-tenant effective capacity drops ~4×. |
| M5 | `TenantConfigLoader` clears both config caches before repopulating | The window scales with tenant count → 500s and spurious `401 no matching key(s) found`. **SUSPECTED** — needs a runtime probe. |
| M6 | Job success gauges roll up across tenants | One bad tenant pins them forever. |
| M7 | Idle evictor never fires on the lock-winning replica | The outbox touches every tenant every 15 s, so the 15-min idle threshold is never reached there. |
| M8 | Flyway readiness goes 2 → 5 serial migrations per boot per replica | Slower rolling deploys. |
| M9 | `cachePrepStmts` / `prepStmtCacheSize` are MySQL property names | Inert on pgjdbc — the documented 250-statement cache does not exist. |
| M10 | `TenantKeyBuilder` truncates tenant name to 4 chars | Latent: a future `shipping-co`/`shipitez` pair sharing a facility code collapses to one pool. Not triggered by these four names. |
| M11 | OMS credential identical across tenant DBs (SBDEV-3181) | Attribution rests entirely on `x-tenant`; ShipItEZ's two warehouses both send `x-tenant: shipitez` to the same URL. **SUSPECTED** risk that one warehouse's export overwrites the other — needs an OMS-side answer. |
| M12 | Missing/misspelled `X-Tenant-ID` produces **no log at all** | `TenantFilter`'s warn is commented out, and a null context routes to the **landlord** DataSource (topology §10.2/§10.11). At one tenant a header bug is obvious; at four it is a silent misroute. Lane-reported, not independently re-verified. |
| M13 | `TenantKeyBuilder.cacheKey` fix is on `release` but **absent on `main`** | The `hydra/nywh` + `shipitez/nywh` pair is exactly the cross-tenant cache collision it was written to fix. Non-issue while prd tracks `release` (§1.2) — becomes live if anything ever deploys `main`. |

---

## 5. Explicitly cleared — checked and fine

- **Error isolation and `TenantContext` hygiene in all 8 cron jobs.** Every one has
  `catch (Exception)` *inside* the tenant loop with `TenantContext.clear()` in a `finally`. Tenant 2
  throwing does not stop tenants 3 and 4, and no context leaks into the next iteration. This was the
  highest-value question in the jobs lane and it has the good answer.
- **All 28 `@Cacheable` key expressions are correctly tenant-prefixed** — re-derived against
  `origin/develop`. The caching doc's §2–§4 claims still hold.
- **Outbox routing is tenant-safe** — `dispatchOne` posts to a per-row `destinationUrl` read from the
  tenant's own DB.
- **Routing keys do not collide** for these four facilities.
- **Auth config resolution** does not go through the broken warehouse lookup (B4).
- **`nirvanaLocation`** is id 0 in all four facilities, so that half of B1 is inert.
- Sequence generation, `RestIdempotencyService`, `AccessService`, `StockSummaryExportJob`'s decorated
  consumer thread, and all three non-`TenantContext` ThreadLocals were checked and are clean.

---

## 6. Documentation drift found along the way

`wms2-tenant-routing-datasource-topology.md` is **past its own re-verify date** (due 2026-08-23).

| Doc | Claim | Reality |
|---|---|---|
| topology §7/§10.7 | "There is no push / webhook mechanism" | Stale — `/actuator/tenantpool` exists (and is broken for `nywh`, B4) |
| topology §9 | "Jasypt is in `pom.xml` but unused" | Stale on `develop` — Jasypt was **removed** (SBDEV-3174); only a comment block remains, pinned by `JasyptNotOnClasspathTest`. Still present on `main`. |
| topology §4.2 | `cachePrepStmts` / `prepStmtCacheSize` documented as effective | MySQL property names, inert on pgjdbc (M9) |
| caching strategy §7 | "SDR write surfaces… no annotation can close it" | Stale — closed by `config/SdrCacheEvictionEventHandler.java` (SBDEV-3176), 13 repository-event handlers |
| scheduled-jobs catalog :330-331 | `OutboxDispatcherJob` and `RestIdempotencyCleanupJob` are `app.cron`-gated | Wrong — `@EnableScheduling` is unconditional (`SchedulingEnablementConfig.java:16`); both fire on every replica |
| scheduled-jobs catalog | — | Neither B2 nor H3 appears anywhere in its landmine section |
| caching strategy | — | Covers `@Cacheable` caches only; has no section for **per-tenant state on a singleton bean**, which is where B1, B3 and H5 all live |
| **greenfield-db-provisioning :92** | "`flyway-core` is `<scope>test</scope>` … **Flyway never runs in production** … all migration is manual `psql`" | **False on all three branches.** See B5 — this is the doc that produces the failure. |
| **database-setup-guide :31** | "**Foundational fact** … the v2 app **does not run Flyway at runtime**" | **False on all three branches.** See B5. |
| this report, earlier drafts (×2) | first "prd runs `main`, 296 commits behind `develop`", then "prd tracks `release`, not `main`" | **Both wrong — see §1.2.** prd tracks `main`; the confusion was branch HEAD vs deployed image drifting both ways in one day. |
| prior project notes | "the authz programme is develop-only, NOT on prd" | **Stale** — `FunctionGuardInterceptor` is in the v0.0.21 image prd runs (§1.2). |

---

## 7. Open questions

1. ~~`main` or a `develop`-based release?~~ **ANSWERED** — fixes target `develop` → `release` builds the UAT/PRD containers; prd tracks `main` by promotion. See §1.2, and note the branch-HEAD-vs-deployed-image hazard recorded there.
2. **Are the Flyway staleness gauges (`stale_total`, `ownership_drift`, `enumeration_failed`)
   actually scraped and alerted?** They are the *only* signal that a tenant's schema has frozen
   (B5), and the boot stays green either way. Cheap to confirm, and it decides whether B5 is a
   documentation fix or an observability gap too.
3. ~~How many wms2-api replicas run in prd?~~ **ANSWERED (Nam)** — 1 today, scaling to 2, max 3.
   Residual: identify what holds the other ~21 `wms2_landlord` connections (§H2).
4. **Does OMS distinguish ShipItEZ's two warehouses?** Both send `x-tenant: shipitez` to one URL
   (M11). This needs an OMS-side answer, not a WMS one.

---

## 8. Method

Four parallel audit lanes over `origin/develop` @ `452d3ed4`, each required to write a report file:
shared/singleton state (A), connection capacity and pool lifecycle (B), background jobs and
integration blast radius (C), onboarding and provisioning (D). Lane D's code-side pass was still in
flight at write time; its docs-side subreport is folded into §6.

Every finding promoted to §2–§3 was **independently re-verified** against the branch that matters and,
where it made a claim about data, against the live databases. Lane reports are retained at
`scratchpad/lane{A,B,C,D}-*.md`.

**Corrections made during synthesis, in both directions** — recorded because the pattern is the point:

| # | Claim | Correction | Source |
|---|---|---|---|
| 1 | B1 writes silently ("nothing rejects it") | An FK **does** exist; today's failure is a loud FK violation, with silent corruption reachable later via overlapping id ranges | lane → me |
| 2 | B2's winner flips to a specific tenant | Bucket order is unspecified; only the *invariant* is dependable | lane → me |
| 3 | Tenant DBs are separate PostgreSQL servers | One instance, shared 300-connection limit, shared with live v1 | me → lane |
| 4 | prd runs `main`, 296 commits behind | prd tracks `release` @ v0.0.21; authz gating is **live on prd** | me → lane |
| 5 | B5 is "green boot, no alert" | Logged at ERROR with a named repair, counted, and gauged — but boot stays green and gauge consumption is unverified | lane → me |

Four of the five were caught only because a claim was re-derived rather than accepted. Findings that
rest on a single unverified assertion are marked SUSPECTED throughout and should be treated as leads,
not conclusions.
