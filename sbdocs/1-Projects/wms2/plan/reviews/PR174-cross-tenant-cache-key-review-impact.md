---
title: PR174 cross-tenant cache key — operational blast radius review
reviewer: independent impact lane (did not author the change)
date: 2026-08-21
target: wms2-api PR #174, bugfix/cross-tenant-cache-key, trial-merged onto origin/develop
scope: exposure / severity / rollout — NOT line-by-line correctness (separate lane)
---

# PR174 — operational blast radius

## Verdict

**Merge to `develop` now. Promote to UAT on the next release-branch cut. Include PRD in the
normal promotion — no separate hotfix, but do not let it sit behind the next tenant activation.**

Three things move this off "quiet correctness cleanup":

1. **The leak was live on UAT and it did not need Redis.** The PR hedges severity on which cache
   manager is active. That hedge is unnecessary. Ten scheduled jobs enumerate every active tenant
   and switch `TenantContext` **sequentially inside a single JVM**, so a JVM-local Caffeine cache is
   sufficient to cross the two `nywh` tenants — on every cron pass, well inside the 2-minute
   `sysprops` TTL. Evidence in §1.
2. **The measured collision surface is much larger than the PR's example.** Not "some entries":
   **114 of shipitez's 122 client numbers** collide, 113 of them resolving to a *different* primary
   key; **195 of shipitez's 200 location names** collide, all with different ids. Per-cache numbers
   in §3.
3. **One crossing has an external, non-recoverable side effect.** `WEBSERVICE_ORDER_BATCH_PALLETIZED`
   / `_LOADED_TO_TRUCK` / `_REVERSAL_COMPLETED` differ between the two tenants — hydra points at
   **`api-oms-dev.siteboss.net`**, shipitez at `api-oms.uat.sbo.li` — and are read through the cached
   `getSysvalue`. A cross-hit posts a UAT tenant's palletize / truck-load notification **to the DEV
   OMS**. Flushing a cache does not un-send that.

PRD is not exposed today (one active tenant, §2), which is exactly why it should get the fix *before*
the next tenant lands rather than after.

Deploy is safe and needs no warm-up (§4). No ordering constraint against today's four SBDEV-3003
commits — **zero file overlap** (§4).

---

## 1. Was this a live leak, and where

### What is knowable from the repo

**Cache inventory** — `src/main/java/net/aim_ai/wms/config/CacheConfig.java`:

| cache | Caffeine maxSize | TTL (both managers) | fronts |
|---|---|---|---|
| `sysprops` | 200 | **2 min** | `SyspropRepository:30` — `select sysvalue … where syskey=:k and workstation='DEFAULT' … LIMIT 1` |
| `clients` | 100 | 5 min | `findByNumber` / id-0 lookup |
| `locations` | 2000 | 5 min | `locationRepository.findByName` |
| `itemdata` | 3000 | 5 min | `findById`, `findByClientIdAndItemNr` |

Caffeine bean at `CacheConfig.java:36-41` (`@Profile("!redis")`), Redis bean at `:57-70`
(`@Profile("redis")`), same TTLs, no size bound.

**The `redis` profile is not activated anywhere in-repo** — confirmed:
- `src/main/resources/application.properties:22-28` only *documents* it ("Activate with:
  `spring.profiles.active=redis`") and sets connection defaults.
- `Dockerfile` — the only `SPRING_PROFILES_ACTIVE` line is commented out
  (`#ENV SPRING_PROFILES_ACTIVE=wineco`).
- No `SPRING_PROFILES_ACTIVE` or `REDIS_*` in `.github/workflows/*` or `.gitlab-ci.yml`.
- The dependency exists (`pom.xml:181`, `spring-boot-starter-data-redis`), so the profile *could* be
  switched on out-of-band.

**Deployment shape** — Portainer, not Kubernetes. There are no k8s/helm manifests in the repo and no
`replicas` key anywhere. Each workflow pokes **two** Portainer webhooks:
- `docker-image-develop.yml:41-45` — DEV, on push to `develop` (**auto-deploy confirmed**)
- `docker-image-uat.yml` (tail) — UAT, on push to `release`
- `docker-image.yml` — builds on `main` but **its Portainer webhook is commented out** → PRD is a
  manual deploy.

Two webhooks per environment ⇒ **at least two containers running this image per environment**
(`wms-api` + a `cron` service, named in the workflow steps). That matters: the cron container is its
own JVM with its own Caffeine cache.

### The mechanism that makes this real without Redis — measured

Ten scheduled jobs loop every active tenant in one JVM, setting `TenantContext` per iteration:

```
ReplenishOrderJob.java:106-127      findByActiveTrue() → for (TenantProfile …) → TenantContext.setCurrentTenant(…)
CleanUpOldMessagesJob.java:73       OrderReleaseJob.java:94
SchedulingConfiguration.java:113,155
ReleaseExpiredPickingOrdersFromUserJob.java:82
OutboxDispatcherJob.java:87         StockSummaryExportJob.java:122
RestIdempotencyCleanupJob.java:65   StaleClubBatchCleanupJob.java:52
TenantHealthService.java:69
```

`ReplenishOrderJob:127` sets the tenant, then `:130-131` immediately calls the **`@Cacheable`**
`syspropService.getSysvalue(...)`. Under the pre-fix key that read lands on `nywh:NEW_CRON_JOB_ACTIVATED`
for *both* nywh tenants.

Loop order, measured on the UAT landlord (`ORDER BY c.id`):

| cfg_id | tenant | warehouse | pre-fix cache prefix |
|---|---|---|---|
| 3 | wineco | wsl | `wsl:` |
| **7** | **hydra** | **nywh** | **`nywh:`** ← populates |
| 13 | shipitez | c1wh | `c1wh:` |
| **14** | **shipitez** | **nywh** | **`nywh:`** ← reads hydra's values |

So the direction is consistent: **hydra populates, shipitez/nywh consumes hydra's values**, every
pass, in the same JVM, seconds apart — far inside the 2-minute `sysprops` TTL. The API container adds
a second, independent path (any two requests for the two nywh tenants on the same replica inside the
TTL), but the cron path alone is sufficient and is not probabilistic.

### Realistic worst case per environment

| environment | manager (presumed) | worst case |
|---|---|---|
| DEV | Caffeine | **None today** — one active tenant (§2). Would apply if the two inactive `nywh` rows were activated. |
| UAT | Caffeine | **Realised.** Wrong-tenant values served for up to one TTL (2 or 5 min) per key, re-established every cron pass and on every restart. Bounded by process lifetime. |
| UAT *if* Redis | Redis | Leak **survives restarts**, propagates to every replica, and the "first writer wins" race becomes global rather than per-JVM. Same key set, longer persistence. |
| PRD | Caffeine | **None today** (single active tenant, §2). |

### Needs someone outside the repo

- **Whether any environment actually runs `SPRING_PROFILES_ACTIVE=redis`** → anyone with Portainer
  access (`portainer.dev.sbo.li`, `portainer.uat.sbo.li`) can read the stack environment in one
  look. If UAT runs Redis, the UAT verdict hardens from "bounded by process lifetime" to "persistent".
- **Replica count of the `wms-api` service per environment** → same person, same screen.

---

## 2. Which tenants and environments are exposed

All three queries were the same shape, run read-only against the landlord MCPs. Note the column is
`tenant_db_configuration.warehouse`, not `facility_code` — `TenantConfigLoader.java:82` lowercases it
into `TenantProfile.facilityCode`.

```sql
SELECT c.warehouse, count(DISTINCT t.name) AS n_active_tenants,
       string_agg(DISTINCT t.name, ', ') AS tenants
FROM tenant_db_configuration c JOIN tenant t ON t.id = c.tenant_id
WHERE c.active = true
GROUP BY c.warehouse ORDER BY n_active_tenants DESC, c.warehouse;
```

| env | landlord DB | result | facility shared by >1 active tenant | exposed |
|---|---|---|---|---|
| **DEV** | `dev_landlord` | `wsl → 1 (wineco)` | no | **NO** |
| **UAT** | `landlord` | **`nywh → 2 (hydra, shipitez)`**, `c1wh → 1 (shipitez)`, `wsl → 1 (wineco)` | **YES** | **YES — measured** |
| **PRD** | `wms2_landlord` | `nywh → 1 (hydra)` | no | **NO** |

Full row listing (`active` included), same join without the filter:

**DEV** — four rows, three of them inactive:

| tenant | warehouse | active | db_url |
|---|---|---|---|
| shipitez | c1wh | **false** | `dev.sbo.li:25060/wh02_hydra` |
| hydra | nywh | **false** | `dev.sbo.li:25060/wh01_hydra_v2` |
| shipitez | nywh | **false** | `dev.sbo.li:25060/wh01_hydra` |
| wineco | wsl | true | `dev.sbo.li:25060/dev_wh01_om1` |

→ **DEV carries a dormant version of the exact collision**: two `nywh` rows, different tenants.
Flipping both to `active=true` (a one-row UPDATE, no code change) recreates it. Also worth flagging
separately: DEV's shipitez rows point at *hydra* databases (`wh01_hydra`, `wh02_hydra`) — that config
is copy-pasted, unrelated to this PR, but it means a DEV activation would produce nonsense regardless.

**UAT** — all four active:

| tenant | warehouse | active | db_url |
|---|---|---|---|
| shipitez | c1wh | true | `uat.sbo.li:25060/wh01_shipitez_v2` |
| **hydra** | **nywh** | true | `uat.sbo.li:25060/wh01_hydra_v2` |
| **shipitez** | **nywh** | true | `uat.sbo.li:25060/wh02_shipitez_v2` |
| wineco | wsl | true | `uat.sbo.li:25060/wh01_om1_v2` |

**PRD** — exactly one row in the whole table:

| tenant | warehouse | active | db_url | created |
|---|---|---|---|---|
| hydra | nywh | true | `100.92.232.69:25060/wh01_hydra_v2` | 2026-06-10 |

`active = false` genuinely removes a tenant from routing — it is not cosmetic:
`TenantDbConfigurationRepository:29` (`findByActiveTrue`), `TenantConfigLoader.java:108-113`,
`TenantDynamicRoutingDataSource.java:226-235` (SBDEV-2727 evicts a pool whose key leaves the
active-filtered cache). So DEV's inactive rows are a *latent* exposure, not a live one.

**What the PRD null result does and does not prove.** It proves there is currently no
facility_code shared by two active tenants on the v2 PRD landlord, so no cross-tenant cache collision
is possible there **on the v2 stack**. It does not prove PRD was never exposed (the row was created
2026-06-10; I have no history of the table), it says nothing about the six v1 databases beside it, and
it is a snapshot: the moment a second tenant is activated on `nywh` — or any facility code is reused —
pre-fix code would collide **silently, with no error and no log line**. Given ShipItEZ (NY `wh02/nywh`
+ LA `wh01/c1wh`) and WineCo are both mid-migration, that is a scheduled event, not a hypothetical.

---

## 3. What data actually crossed

Measured by comparing the two colliding UAT tenant databases directly
(`nywh-hydra-uat` = `wh01_hydra_v2`, `nywh-shipitez-uat` = `wh02_shipitez_v2`).

### Per-cache collision surface

| cache | key shape (pre-fix) | measured collisions | wrong-hit meaning | feeds DB/external writes |
|---|---|---|---|---|
| **`sysprops`** | `nywh:<syskey>` | key sets are near-identical; **20 keys hold different values** (table below) | wrong-tenant configuration governs behaviour | **YES — replenish, order release, cycle count, label printing, outbound OMS calls** |
| **`clients`** | `nywh:<clNr>`, `nywh:SYSTEM` | **114 of shipitez's 122 client numbers also exist in hydra; 113 of them resolve to a DIFFERENT `client.id`.** Only `System` (id 0 both sides) is benign | a wrong-tenant `Client` **primary key** handed to 58 call sites | **YES — putaway destination resolution** |
| **`locations`** | `nywh:<name>` | **195 of shipitez's 200 location names also exist in hydra** (665 hydra names). Id ranges are disjoint (hydra ~3.2M, shipitez ~0.4M), so every colliding name carries a different id | a wrong-tenant `Location` **primary key** | **YES — move / putaway targets** |
| **`itemdata`** | `nywh:id:<id>`, `nywh:<clientId>:<itemNr>` | **ZERO on both key shapes** — verified | — | n/a |

The `itemdata` zero is verified, not assumed:
- `clientId:itemNr` shape — the two tenants' `client.id` sets intersect only at `0` (System); hydra
  has 1 item at client 0 (`ICE PACK`), shipitez has **0** items at client 0. No shared key possible.
- `:id:` shape — `SELECT count(*) FROM itemdata WHERE id BETWEEN …` over all 18 blocks spanning
  shipitez's entire id space, run against hydra: **0**. The sequences were seeded independently, so
  the id spaces are disjoint. **This is luck, not design** (cf. the known `seqentities` dual-island
  behaviour on migrated DBs) — a freshly-seeded tenant pair would collide here too.

The colliding `locations` names include every operationally significant lane and zone:
`StagingLane01-06`, `TransferLane01-06`, `Gate_01-06`, `INV-Z01-30`, `PutAwayLane`, `Nirwana`,
`Shipped`, `Palletizing`, `Packaging`, `Clearing`, `Damaged`, `CycleCount`, `EmptyPallets`,
`EmptyTotes`, `FinishedPicking`, `PickUp_Zone`, `Spawn`, `Transfer`, `InboundWorkstation`,
`TCOMPANY-01..12`, plus **112 rack/bin locations** (`A2005-A-1` … `A2008-B-6`, `A1001-Z-F` …).

### `sysprops` — the 20 keys whose values actually differed

Sensitive or decision-bearing, **and confirmed reachable through the cached `getSysvalue`**:

| syskey | hydra/nywh | shipitez/nywh | cached read site | operational meaning |
|---|---|---|---|---|
| `OMS_TENANT_ID` | `hydra` | `shipitez` | `HttpRestService.java:97` → `headers.set("x-tenant", …)` | **Every outbound OMS call is stamped with the wrong tenant identity.** A cross-tenant *write* into the OMS. |
| `WEBSERVICE_ORDER_BATCH_PALLETIZED` | `api-oms-dev.siteboss.net/…/palletized` | `api-oms.uat.sbo.li/…/palletized` | `ManageOrderService.java:340` | **Notification posted to the wrong OMS environment.** Non-recoverable external side effect. |
| `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` | `api-oms-dev.siteboss.net` | `api-oms.uat.sbo.li` | same family | as above |
| `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` | `api-oms-dev.siteboss.net` | `api-oms.uat.sbo.li` | same family | as above |
| `PICKING_BOX_PER_CART` | `8` | `6` | `ReplenishOrderJob.java:222` → `parseSyspropLong` → `:497 getSysvalue` | parameterises **picking-order merging** — a DB write |
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT` | `false` | `true` | `MobileCycleCountService.java:252` | reveals the expected count to the counter → **biases counts that are written as inventory adjustments** |
| `PRINTING_DEFAULT_AMOUNT_TOTE_LABEL` | `1` | `25` | `LabelPrintingService.java:1004` → `getIntValue` → `SyspropService:294 getSysvalue` | prints 25 tote labels where 1 was configured, consuming 25 sequence numbers |

Note the shape of `HttpRestService.applyHeaders` — **both** the outbound OMS **Basic-Auth credential**
(`OMS_API_USER`, `:88`) and the tenant identity (`:97`) are resolved through the facility-keyed cache.
That is the sharpest form of the PR's "plaintext secrets" claim: the credential path itself ran through
the collision. In *this* tenant pair `OMS_API_USER` happens to be identical
(`api_user/apiUser@sb` on both), so no credential actually crossed — but the mechanism did.

Differ, sensitive, but **not** reachable through a cached read (latent, not leaked):

| syskey | hydra | shipitez | why not leaked |
|---|---|---|---|
| `KEYCLOAK_CLIENT` | `om1-api/1Gjj` | `om1-api/ZLchgUjI8TeShGwmlPVZLGZnaPcFQ5i8` | **a differing embedded client secret**, but `SYSTEM_PROPERTY_KEYCLOAK_CLIENT_KEY` has only commented-out references (`UtilRestController.java:157`) |
| `KEYCLOAK_OMS_USER_PREFERRED_SCHEMA` | `om1_hydra` | `om1_shipitez` | no Java reference at all to the constant |
| `KEYCLOAK_OMS_USER_GROUP` | `client_hydra` | `client_shipitez` | untraced — see §5 |
| `KEYCLOAK_APP_GROUP_NAME` | `app_wms_wh03` | `app_wms_wh05` | untraced — see §5 |

Present in the table, **plaintext, and identical on both tenants** — so the PR's claim that `sysprops`
holds plaintext secrets is **confirmed true**, though these two specific ones neither differed nor are
read through the cache (both constants appear only in commented-out `UtilRestController` lines):
- `WMS_LOGIN_SECRET` = `cbc71da7-6a2b-4dbf-babb-1e8155f63dab`
- `CUPS_SERVER_ADDRESS_PASSWORD` = `cupsAdmin@sb`

Differ, merely stale / cosmetic:
`MOBILE_UI_URL`, `MOBILE_UI_REDIRECT_URL`, `WEB_UI_REDIRECT_URL` (point at the other tenant's host —
`wh03.komatik.co` vs `wh05.komatik.co`, `nywh-hydra…` vs `nywh-shipitez…`; a cross-hit redirects a
user toward the other tenant's UI), `SYSTEM_OMS_NAME`, `City / Town` (New York / Troy),
`State / Province`, `Zip` (10005 / 12180 — printed on labels and paperwork).

One asymmetric key: `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS` exists only on shipitez
(`1787320283516`). Because `getSysvalue` carries `unless = "#result == null"`, hydra's absent read is
*not* cached but shipitez's value **is** — so hydra would read shipitez's watermark and could conclude
a recalculation had already run. I could not locate a Java reader for this exact key name; flagged in §5.

### Which caches cause durable damage vs a cosmetic glitch

**Durable — a wrong read changes what gets written:**

- **`clients` → putaway placement.** `PutawayDestinationResolver.java:107-109` reads
  `client.getDefaultputawaylocationId()` and calls `requireConfiguredLocation(...)`; `:211` does the
  same via `clientService.getSystemClient()`. The `Client` comes from the `@Cacheable`
  `getByNumber` / `getSystemClient`. A cross-tenant `Client` therefore supplies **the other tenant's
  putaway location id**, resolved against the *current* tenant's `location` table. Because the id
  ranges are disjoint, this lands as "not found" (a hard putaway failure) far more often than as a
  plausible-but-wrong location — but the failure mode is a wrong or refused putaway destination, not
  a rendering artefact.
- **`sysprops` → replenishment, order release, cycle count, label printing, and the outbound OMS
  notifications** (table above). The OMS notifications are the worst of these because the damage
  leaves the system.
- **`locations` → move / putaway targets** via `LocationService.getByName` (2 callers) — a
  wrong-tenant `Location` primary key.

**Already guarded — worth recording so it is not re-litigated:** both write entry points for
`setPutAwayLocation` deliberately bypass the cached accessor and load the entity from the repository,
with an explicit comment:

- `ItemDataController.java:113-118` — *"Load the ENTITY from the repository, never the `@Cacheable`
  accessor: the writer mutates the instance it is handed…"*
- `PutawayConfigController.java:186-192` — same, tagged N-4.

So the "mutate a cached cross-tenant entity in place and save it" route is **closed at those two
sites**. The durable channel is the *decision* route (config and foreign keys), not entity identity.

**Cosmetic:** the UI URLs, OMS display name, address fields.

**Benign despite colliding:** the `nywh:SYSTEM` key. The System client is `id = 0` in both tenants, so
`UnitloadService.java:204` and `ParcelMonitorViewService.java:121,143,287,309`, which write
`clientId = getSystemClient().getId()`, are unaffected. The *other* fields on that shared System
`Client` — notably `defaultputawaylocationId` — are not benign; see `PutawayDestinationResolver:211`.

---

## 4. Deploy-time behaviour

**Orphaning every entry is a non-event.**
- Under Caffeine the caches are JVM-local and the container restarts on deploy, so there is literally
  nothing to orphan — this deploy is indistinguishable from any other restart.
- Under Redis, the cache name is the Redis key prefix, so pre-fix entries sit under
  `sysprops::nywh:<key>` and post-fix under `sysprops::hydra:nywh:<key>`. Old entries are unreachable
  and expire on their own TTL (**≤5 min**), costing a few kilobytes in the interim. No manual flush
  needed.

**No stampede concern.** All four caches front **single-row indexed lookups**, not expensive
aggregates:
- `SyspropRepository.java:30` — `select sysvalue from los_sysprop where syskey=:k and workstation='DEFAULT' order by client_id LIMIT 1`
- `clientRepository.findByNumber`, `locationRepository.findByName`, `itemdataRepository.findById`

Worst case is one extra single-row query per (tenant, key) on first touch, bounded by the maxSizes
(200 / 100 / 2000 / 3000) across four tenant-warehouse partitions on the largest environment. A cold
cache after container restart is already the steady state. **No warm-up, no phased rollout.**

**One real, mild regression to note.** Adding a tenant dimension to the key multiplies the working set
while the Caffeine `maximumSize` values are unchanged. `clients` is capped at **100** and hydra alone
has **138** clients — that cache was already thrashing before this change, and partitioning it makes
the hit rate worse. Pre-existing under-sizing, made slightly more visible; a follow-up size bump, not
a blocker on this PR.

**Ordering against the four SBDEV-3003 commits on `develop`: none.**

| PR174 touches | SBDEV-3003 commits touch |
|---|---|
| `controller/SystemPropertyController.java` | `landlord/config/IdempotencyFilter.java` |
| `landlord/config/TenantKeyBuilder.java` | `service/RestIdempotencyService.java` |
| `service/{Client,Itemdata,Location,PutawayConfig,Sysprop}Service.java` | `Authority.java`, `SecurityConfiguration.java` |
| `test/unit/config/TenantCacheKeyUnitTest.java` | `util/OptimisticLockRetry.java` + tests |

**Zero file overlap**, and no semantic interaction — idempotency keys are DB rows in a tenant table,
not Spring cache entries. The trial merge (`007975f` onto `cdd85d9`) is clean. Merge in either order.

**Residual, unchanged by this PR (one line, for the record):** the `no-tenant` bucket is still a
single shared partition, exactly as the old `"null:<key>"` bucket was. It is largely inert because a
null tenant routes to the **landlord** database (`TenantDynamicRoutingDataSource.java:51-54`), which
has no `los_sysprop` / `client` / `location` tables, so such reads fail rather than populate. Neither
improved nor worsened here.

---

## 5. Recommendation

**`develop`: merge now.** Safe, no prerequisites, no ordering constraint, and DEV is not itself
exposed so nothing changes behaviourally there.

**UAT: promote on the next release-branch cut — treat as prompt, not as a hotfix.** UAT is the only
environment where the collision is live, and it is where hydra/shipitez acceptance testing happens.
Two concrete reasons not to let it drift:
- Any nywh anomaly the UAT testers are currently chasing — wrong putaway destinations, cycle-count
  screens showing expected amounts they should not, 25 tote labels instead of 1, replenishment
  behaving unlike its configuration — is plausibly this bug rather than the feature under test.
- The `api-oms-dev.siteboss.net` divergence means **UAT palletize / truck-load / reversal
  notifications have plausibly been posting to the DEV OMS**. That is worth checking on the OMS side
  independently of this merge (§ below).

**PRD: include in the normal promotion; no separate action, but do not defer it past the next tenant
activation.** Today the fix is a functional no-op on PRD — one active tenant, no collision possible.
The reason to ship it anyway is sequencing: `main` is **35 commits behind `develop`**
(`git rev-list --count origin/main..origin/develop`), currently at OWL v2.0.128 / wms2-api v0.0.17
(`cf430ff`), and PRD deploys manually (`docker-image.yml`'s Portainer webhook is commented out). With
ShipItEZ (NY `wh02/nywh` + LA `wh01/c1wh`) and WineCo mid-migration, the next PRD tenant activation
would otherwise walk a pre-fix build straight into a **measured, silent, cross-tenant data leak** —
no exception, no log line, and a first-writer-wins race deciding which tenant's data the other sees.
Ship the fix before the tenant, not after.

**Not recommended:** a PRD hotfix or an out-of-band tag. Nothing on PRD is currently wrong.

---

## 6. What could not be determined from here, and who can

| # | Unknown | Impact if it goes the other way | Who / what resolves it |
|---|---|---|---|
| 1 | Whether any environment sets `SPRING_PROFILES_ACTIVE=redis` in its Portainer stack env | UAT leak changes from "bounded by process lifetime" to "persists across restarts, spans all replicas" | Anyone with Portainer access — `portainer.dev.sbo.li`, `portainer.uat.sbo.li`, and the PRD stack. One screen. |
| 2 | Replica count of the `wms-api` service per environment | Raises the pre-fix collision rate on the API path (the cron path is unaffected by replica count) | Same person, same screen. Two webhooks per env implies ≥2 containers (api + cron); says nothing about api replicas. |
| 3 | Whether the collision produced a *specific* observed UAT defect | Would convert this from "measured exposure" to "measured incident" | **OMS side, not WMS.** Check whether `api-oms-dev.siteboss.net` received `palletized` / `loadedToTruck` / `batchReversalCompleted` callbacks carrying shipitez data, and whether any shipitez batch arrived at the UAT OMS with `x-tenant: hydra`. |
| 4 | Read paths for `KEYCLOAK_APP_GROUP_NAME` and `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS` | Would add (or remove) two rows from the §3 "actually crossed" table | Grep-traceable in-repo; I ran out of scope before tracing them. Neither changes the verdict. |
| 5 | Historical blast radius — how many wrong-tenant reads were actually served | Sizing only; does not change the fix | **Not recoverable.** Nothing logs cache hits. `recordStats()` is enabled (`CacheConfig.java:80`) but the stats are aggregate, in-memory, and not persisted. |
| 6 | Whether PRD was ever exposed historically (before 2026-06-10, or via rows since deleted) | Retrospective only | Landlord DB backups / audit trail, if any exist. The current table has one row and no history. |

---

## Appendix — queries run (all read-only)

```sql
-- §2, run against landlord-dev, landlord-uat, landlord-prd
SELECT current_database();

SELECT c.warehouse, count(DISTINCT t.name) AS n_active_tenants,
       string_agg(DISTINCT t.name, ', ') AS tenants
FROM tenant_db_configuration c JOIN tenant t ON t.id = c.tenant_id
WHERE c.active = true
GROUP BY c.warehouse ORDER BY n_active_tenants DESC, c.warehouse;

SELECT t.name AS tenant, c.warehouse, c.active, c.db_url
FROM tenant_db_configuration c JOIN tenant t ON t.id = c.tenant_id
ORDER BY c.warehouse, t.name;

-- loop order for the cron collision (§1)
SELECT c.id AS cfg_id, t.id AS tenant_id, t.name, c.warehouse, c.active
FROM tenant_db_configuration c JOIN tenant t ON t.id = c.tenant_id
WHERE c.active ORDER BY c.id;

-- §3, run against nywh-hydra-uat and nywh-shipitez-uat
SELECT syskey, sysvalue FROM los_sysprop WHERE workstation = 'DEFAULT' ORDER BY syskey;

SELECT (SELECT count(*) FROM client)   AS n_clients,
       (SELECT string_agg(id||'='||cl_nr, ', ' ORDER BY id) FROM client) AS clients,
       (SELECT count(*) FROM location) AS n_locations,
       (SELECT count(*) FROM itemdata) AS n_items;

SELECT string_agg(name, E'\n' ORDER BY name) FROM location;

SELECT count(*) FROM itemdata WHERE client_id = 0;

-- itemdata :id: overlap — shipitez's full id space, counted against hydra (result: 0)
SELECT count(*) FROM itemdata
WHERE id BETWEEN 52300 AND 52349 OR id BETWEEN 55500 AND 55533
   OR id BETWEEN 62350 AND 62399 OR id BETWEEN 93250 AND 93299
   OR id BETWEEN 184400 AND 184449 OR id BETWEEN 306290 AND 872763
   OR id BETWEEN 1201800 AND 1201849 OR id BETWEEN 1789500 AND 1789549
   OR id BETWEEN 2347900 AND 2347949 OR id BETWEEN 2928150 AND 2928199
   OR id BETWEEN 3875050 AND 3875099 OR id BETWEEN 4671250 AND 4671299
   OR id BETWEEN 6310500 AND 6310518 OR id BETWEEN 7089100 AND 7089149
   OR id BETWEEN 9436950 AND 9436999 OR id BETWEEN 10017800 AND 10017849
   OR id BETWEEN 11542900 AND 11542949 OR id BETWEEN 14451150 AND 14451155;
```

Client-number and location-name intersections were computed locally (`comm -12`) from the
`string_agg` outputs above:
- clients — 137 hydra `cl_nr` vs 122 shipitez `cl_nr` → **114 shared**, of which **1** (`System`,
  id 0) shares its id; **113 resolve to different ids**.
- locations — 665 hydra names vs 200 shipitez names → **195 shared**, 112 of them `A#…` rack/bin
  locations.

Measured vs inferred:
- **Measured**: every table and count above; the loop order; the cron tenant-iteration code paths;
  the absence of the `redis` profile in-repo; the file-overlap check against SBDEV-3003.
- **Inferred**: that Caffeine is the active manager in every environment (follows from the profile
  being unset in-repo, but the Portainer env is not visible — item 1 in §6); that ≥2 containers run
  per environment (from two Portainer webhooks per workflow); that the `itemdata` id spaces are
  disjoint *by construction* rather than coincidence (the zero-overlap count is measured; the
  independent-sequence-seeding explanation is inference).
