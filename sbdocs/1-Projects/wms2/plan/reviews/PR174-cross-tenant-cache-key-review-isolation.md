---
title: "PR #174 review — cross-tenant cache key partitioning (data-isolation lane)"
ticket: none (T1 path, no ticket)
pr: SiteBossInc/wms2-api#174
branch: bugfix/cross-tenant-cache-key
reviewer: independent isolation lane (did not author the change)
date: 2026-08-21
verdict: merge-with-changes
last_verified: 2026-08-21
---

# PR #174 — cross-tenant cache key partitioning

**Review lane:** data isolation / completeness / test adequacy. I did not write this code. Trial-merged onto `origin/develop` at `007975f` in
`/tmp/claude-1000/-home-nampark-dev-wms-claude/74e9ade3-54f9-40c9-b7fd-5f0d8ec80cce/scratchpad/trial174`.

## Verdict: **merge-with-changes**

**The production change is correct and I independently confirmed the leak is closed.** I enumerated the cache-annotation surface myself, evaluated all 23 SpEL keys under two tenants that share a facility code, and found no cross-tenant collision and no evict/`@Cacheable` pair mismatch. `mvn clean compile` clean; full suite 5245 run / 2 failures, both the known pre-existing ones.

**What blocks a clean merge is the guard test, not the fix.** I ran 13 mutants; **5 survived**. One of them (M6) restores the *full original cross-tenant leak* — every tenant collapsing into one shared bucket — while leaving all 6 tests green. For a data-isolation guard whose stated purpose is preventing exactly that, and which the PR itself reports was blind three separate times already, that is not good enough to be the thing standing between this bug and its return.

The recommended change is small: **evaluate the SpEL in the test instead of string-matching it.** ~30 lines kills 4 of the 5 survivors (M4, M6, M7, M11-class) at once. The fifth (M8/M14) needs the hardcoded class list replaced with a classpath scan.

I found **no High-severity defect**: no cross-tenant leak, no permanently-broken evict, no wrong data served.

---

## Findings

| # | Sev | Location | What breaks | Fix |
|---|-----|----------|-------------|-----|
| **1** | **Medium** | `TenantKeyBuilder.java:52-57` + `TenantFilter.java:41-49` | **Cache partitions are now finer than tenant identity.** `X-Tenant-ID` is an unvalidated client header, and only its **first 4 chars** select the database. `X-Tenant-ID: hydra` and `X-Tenant-ID: hydraXX` (both `facility_code: nywh`) authenticate against the same realm, route to the same DB, and are the same tenant to Hibernate — but now occupy **different cache partitions**. Consequences: (a) an evict under one spelling never clears the entry cached under another → stale read, TTL-bounded at 2–5 min; (b) one authenticated user can mint unbounded partitions in the size-capped *shared* caches, evicting other tenants' entries by size pressure. **Not a leak** — each partition is still fed only from that tenant's own DB. | `.trim()` the headers in `TenantFilter`; better, derive the cache key from the canonical tenant name in the landlord config rather than the raw header, or validate the header against the landlord tenant list. |
| **2** | **Medium** | `TenantCacheKeyUnitTest.java:126-176` | **`cacheKey(null)` passes every assertion (mutant M6 survived).** A key written `...cacheKey(null) + ':' + #key` contains the literal `cacheKey(` and is non-empty, so all three collection assertions pass — while every tenant collapses into the shared `no-tenant` bucket. This is the original bug in full, restored, with 6/6 green. | Evaluate the SpEL: assert two distinct `TenantProfile`s yield distinct strings for each of the 23 keys. Also kills M4 and M11. |
| **3** | **Medium** | `TenantCacheKeyUnitTest.java:126-176` | **Evict/`@Cacheable` pair divergence is unguarded (mutant M7 survived).** Changing `':id:'`→`':idx:'` in one nested `ItemdataService` evict leaves 6/6 green while that evict can never again clear the entry its `@Cacheable` writes. The PR says the review lane verified pair equality "against evaluated values" — that check was throwaway and **is not in the committed suite**, so nothing prevents its regression. This is the most dangerous failure mode in the file (invisible in tests, obvious in production) and it is the one with no test. | Group the 23 *evaluated* keys by cache name; assert every `@Cacheable`/`@CachePut` value has a matching `@CacheEvict` value. |
| **4** | **Medium** | `TenantCacheKeyUnitTest.java:56-60` | **The class list is hardcoded and the walk is `getDeclaredMethods()` (mutants M8 + M14 survived).** M8: a facility-only `@Cacheable` in a *new* class is wholly invisible — the count pin stays 23. M14: a facility-only `@Cacheable` on `AdminController`, **base class of 43 controllers**, is invisible to `getDeclaredMethods()` on the two subclasses that *are* listed. The PR's own narrative is that this test's recurring defect is "a collection walk that silently excludes the cases it exists to guard," fixed three times — **the collection of _classes_ is the fourth instance and is still open.** | Replace the literal list with a classpath scan / ArchUnit rule over `net.aim_ai.wms..` — the repo already uses ArchUnit. That also removes the need for the count pin. |
| **5** | **Low** | `TimezoneService.java:37,62,76,97-102` | **A second tenant-scoped cache was not swept.** `ConcurrentHashMap<String, ZoneId>` keyed on `TenantKeyBuilder.buildKey` — the truncating key this PR's own javadoc rejects for cache use ("would leave two tenants sharing a 4-char prefix AND a facility code still colliding"). **Latent, not live**: no two active tenants share first4+facility. Separately, `invalidateCache`/`invalidateCacheAll` have **zero callers** in `src/main` or `src/test`, and the map has no TTL and no size bound — a tenant's timezone is cached for the process lifetime. Outside the PR's declared scope (the 23 annotations) but contradicts "every cache key in this application". | Key it on `cacheKey`, or state explicitly that this cache is out of scope. Wire up or delete the dead evictors. |
| **6** | **Low** | `FileImportController.java:314`, `SkuRestController.java:67,180`, `IdempotencyFilter.java:420-423` | **3 `allEntries = true` evicts on `itemdata` wipe every tenant's entries**, as does `cacheEvictOnReplay` → `itemdataCache.clear()`. Over-eviction is correctness-safe (never serves wrong data) but under the `redis` profile it is cross-replica and cross-tenant. Pre-existing, unchanged. **The test's decision to skip them is correct** — and the "convert a keyed evict to `allEntries=true`" mutant (M9) is still killed by the count pin, so the skip is not a hole. | None required. Already documented in the PR. |
| **7** | **Low** | `SyspropService.java:95` + `:288` | `getByKey(String)` and `getSysvalue(String)` share cache `sysprops` **and a byte-identical key** with different return types — my probe grouped all four `sysprops` sites onto `hydra:nywh:SYSKEY`. First writer wins; the other caller gets a `ClassCastException`. I **confirmed the PR's claim** that the 1-arg `getByKey` has zero callers (`:97` is its own delegation, `:102` is javadoc), so it is latent-unreachable. Pre-existing, unchanged. | None in this PR. Worth a comment on `:95` so the next caller doesn't walk into it. |
| **8** | **Low** | `PutawayConfigService.java:170,390` | **The two `DEFAULT_PUTAWAY_LOCATION` `sysprops` evicts are probably no-ops.** That sysprop's read path is a direct `syspropRepository.findBySyskeyAndClientIdAndWorkstation` (`:592-594`) which bypasses the `@Cacheable` accessors, and nothing calls `getSysvalue("DEFAULT_PUTAWAY_LOCATION")` — so there is likely no entry to evict. Pre-existing and shape-preserved by this PR (prefix changed identically on both sides). Flagged only so it is not mistaken for a pair mismatch — my probe reports it as "EVICT-ONLY" for exactly this reason. | None required. |
| **9** | **Nit** | PR description | The description mentions `@CachePut`; there are **zero** `@CachePut` annotations in `src/main`. | Drop the mention. |

---

## Independent verification of the fix itself

I did not take the PR's word for any of the following.

**Completeness — is 23 the true total?** Yes. Enumerated by hand over all of `src/main`:

| Annotation | Real sites (excl. javadoc) |
|---|---|
| `@Cacheable` | 7 |
| `@CacheEvict` | 19 — of which **3** are `allEntries=true`, keyless |
| `@Caching` | 5 (containers, carry no key of their own) |
| `@CachePut` | 0 |

7 + (19 − 3) = **23 keyed sites**, and a reflection walk that unwraps `@Caching` counted exactly 23. The count pin is arithmetically correct.

**All 23 parse and evaluate.** I wrote a throwaway probe (`SpelExpressionParser` + `MapAccessor`, since deleted) that parsed and evaluated every key under `hydra/nywh`, `shipitez/nywh`, and a cleared context. **Zero parse/eval failures.** This matters because nothing in CI evaluates these expressions — `standaloneSetup` installs no cache advisor and the `@SpringBootTest` lane is down (SBDEV-2217) — so a malformed key would first fail at runtime.

**No cross-tenant collision.** For all 23 keys, `hydra` and `shipitez` on the shared `nywh` facility produced different strings. The 23 keys collapse to 7 distinct value groups per tenant, all correctly prefixed `hydra:nywh:` / `shipitez:nywh:`. **The reported bug is genuinely fixed.**

**Evict/`@Cacheable` pairs match.** Grouping evaluated values by cache name found exactly one apparent orphan — `sysprops || hydra:nywh:DEFAULT_PUTAWAY_LOCATION`, EVICT-ONLY — which is a **probe artifact**, not a defect: the evict uses the `WmsConstants` literal while the read path binds `#key`, so my fixture value (`SYSKEY`) grouped separately. Ruled out; see finding 8 for the real (pre-existing) observation about that pair.

**`cacheKey` vs `buildKey` — the stated reasoning holds.** `buildKey` truncates to 4 chars (`TenantKeyBuilder.java:21-25`); reusing it would leave two tenants sharing a prefix *and* a facility still colliding. Using the full name is correct. And the new key is strictly finer than the routing key, so **no two databases can share a cache key** — the isolation property the PR claims is real. (The *converse* — partitions finer than databases — is finding 1.)

---

## Mutation results

Baseline: `TenantCacheKeyUnitTest` **6/6 green**. Every mutant applied to the trial-merge worktree, test run, then reverted.

| # | Mutant | Result |
|---|--------|--------|
| M1 | Revert one standalone `@Cacheable` to facility-only | **KILLED** (2 failures) |
| M2 | Revert one `@Caching`-nested `@CacheEvict` to facility-only | **KILLED** (2 failures) — the `@Caching` unwrapping works |
| M3 | Delete a `key` attribute entirely | **KILLED** (1 failure) — the empty-key assertion works |
| M4 | `cacheKey`: remove the `':'` separator | ⚠️ **SURVIVED** |
| M5 | `cacheKey`: return `facilityCode` only (re-introduce the bug in the helper) | **KILLED** (2 failures) |
| M6 | Pass `null` to `cacheKey` on one key (all tenants → `no-tenant`) | ⚠️ **SURVIVED** |
| M7 | Diverge an evict/`@Cacheable` pair suffix (`':id:'`→`':idx:'`) | ⚠️ **SURVIVED** |
| M8 | New facility-only `@Cacheable` in a class **not** in `CACHE_HOLDERS` | ⚠️ **SURVIVED** |
| M9 | Turn a keyed `@CacheEvict` into `allEntries = true` | **KILLED** (1 failure) — count pin catches it |
| M10b | Add a facility-only `@Cacheable` to a **covered** class | **KILLED** (2 failures) |
| M11 | `cacheKey`: return a constant (total collapse) | **KILLED** (3 failures) |
| M14 | Facility-only `@Cacheable` on the **inherited** base class `AdminController` | ⚠️ **SURVIVED** |
| M15 | `cacheKey` null-branch returns `""` | **KILLED** (1 failure) |

**8 killed, 5 survived.** Renaming `cacheKey` is killed at compile time (the test calls it directly), so I did not count it as a mutant.

Severity ranking of the survivors: **M6 > M7 > M8/M14 > M4.** M6 restores the entire original defect. M7 silently breaks an evict. M8/M14 leave the guard structurally unable to see new or inherited annotations. M4 enables a `(tenant=ab, fac=cd)` vs `(tenant=a, fac=bcd)` collision — theoretical against current tenant names, but the separator is the only thing preventing it and nothing tests for it.

---

## Checked and ruled out

Stated so a reader can tell coverage from silence.

- **The `no-tenant` bucket is a shared bucket but *not* a cross-tenant leak.** This looked like the most likely High finding and it is not one. `TenantDynamicRoutingDataSource.determineTargetDataSource` (`:49-53`) routes a null tenant — **and a non-null tenant with a null facility** — to the **landlord** datasource (`setDefaultTargetDataSource(landlordDataSource)`, `:39`). So every `no-tenant:*` entry is populated from one single database, and the bucket is a *correct* partition for it, not a mixing point. It is also **not a regression**: the pre-fix `?.` form produced an equally shared `null:*` bucket. Residual nit: a non-null profile with a null facility yields `"<name>:null"` while reading the landlord DB — per-name fragmentation over one DB, not a leak; unreachable from `TenantFilter` (both headers required) and scheduled jobs build profiles from landlord config.
- **`TenantContext` ThreadLocal propagation into the threads these caches are used from.** All 9 scheduled jobs set the context per tenant before doing work (`OrderReleaseJob:94`, `ReplenishOrderJob:127`, `OutboxDispatcherJob:87`, `CleanUpOldMessagesJob:73`, `StaleClubBatchCleanupJob:52`, `StockSummaryExportJob:122`, `RestIdempotencyCleanupJob:65`, `ReleaseExpiredPickingOrdersFromUserJob:82`, `SchedulingConfiguration:113,155`). `@Async`/executor threads are covered by `TenantAwareTaskDecorator`, which sets and restores. No path found where a cache-annotated method runs under tenant A's *datasource* while evaluating tenant B's *key* — key and route both read the same ThreadLocal at the same moment.
- **`IdempotencyFilter` clearing the `itemdata` cache directly** (`:420-423`) — it is a full `clear()`, so it is tenant-blind by construction, but over-eviction is correctness-safe. Covered in finding 6. It does **not** hand-build a key, so it cannot go stale against the new format.
- **Hand-built key strings elsewhere that the rename would strand.** Grepped every `buildKey`/`cacheKey` caller. No code constructs a `sysprops`/`clients`/`itemdata`/`locations` key string by hand to look up or evict an entry. The only hand-built tenant cache key is `TimezoneService`'s, which is a *different* map with its own key space (finding 5) — nothing crosses. **No silently-broken evict from the key-format change.**
- **Cache annotations on base classes.** `AdminController` (base of 43 controllers) currently carries **no** cache annotation, so M14's blind spot is a latent structural gap, not a live miss. `SkuRestController extends AbstractRestController` — also clean.
- **Cache names shared between classes where only one was fixed.** `itemdata` spans `ItemdataService`, `PutawayConfigService`, `FileImportController`, `SkuRestController`, `IdempotencyFilter`; `clients` spans `ClientService`, `PutawayConfigService`; `sysprops` spans `SyspropService`, `PutawayConfigService`, `SystemPropertyController`. **All keyed sites in all of these were retargeted** — no half-fixed cache name.
- **Annotations with no `key` attribute at all.** Exactly 3, all `allEntries = true` (finding 6). None relies on Spring's tenant-blind default key generator. The test's `noneMatch(String::isEmpty)` assertion correctly guards against one being introduced (M3 killed).
- **Other Spring cache annotations reached via `cacheManager.getCache(...)`** — only `IdempotencyFilter`. `TenantAuthConfigCache`, `TenantDbConfigCache`, `TenantDynamicRoutingDataSource.poolHolders` and `MultiTenantJwtDecoder.jwtDecoders` are landlord-level maps keyed on tenant name or `buildKey`; they hold no tenant *business* data and are outside this change's scope.
- **`condition` / `unless` attributes.** Only `SyspropService:288` (`unless = "#result == null"`); not key-affecting.
- **Orphaned entries on deploy.** Confirmed harmless: every cache has a 2–5 min TTL (`CacheConfig:36-39` Caffeine, `:53-68` Redis), so the first read per tenant after deploy is a miss and old entries age out. No migration, DDL, sysprop, or config change needed — the PR's "no deploy prerequisites" claim holds. **This TTL also caps the worst case of every mis-partitioning finding above at 2–5 minutes of staleness.**
- **Regressions.** `mvn clean compile` exit 0. Full suite **5245 run, 2 failures, 0 errors** — `OptionalSafetyArchTest#noNewOptionalGetCallsInServiceClasses` and `MobilePalletizingServiceTest` (`testScanParcelBulkPalletAlreadyAssignedToGate`, asserting on "Pallet already…"), both the documented pre-existing pair. (Stated baseline was 5244; the 1-test delta is a count discrepancy, not a new test failure.) No new failure attributable to this branch.

## Housekeeping

`git status --porcelain` in the trial worktree shows only `M src/test/resources/archunit_store/5fb3fee0-…`, which was **already dirty when I arrived** (6 deletions, pre-existing). I byte-compared it against a copy taken before my first command: **unchanged by my runs.** All mutants reverted; the throwaway SpEL probe deleted. Nothing committed, amended, or pushed.
