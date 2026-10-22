---
name: sbdev-3176-sdr-cache-eviction
description: "SBDEV-3176 MERGED `on dev` 3faa32b6 (PR #262) — SDR writes evict no cache; fixed with a second @RepositoryEventHandler, but @Order(HIGHEST_PRECEDENCE) is REQUIRED and SDR's search controller publishes no event at all, so exported @Modifying queries need their own @CacheEvict"
metadata: 
  node_type: memory
  type: project
  originSessionId: 6cb9776e-0d51-4b37-8a7e-cab8197878f9
  modified: 2026-09-01T18:09:48.193Z
---

**MERGED `on dev`** 2026-09-01 — merge commit **`3faa32b6`**, [PR #262](https://github.com/SiteBossInc/wms2-api/pull/262),
commits `4d3000fd` + `2295d3d4` off `92ca2e38` (base unmoved at merge, so the suite evidence was current).
Suite 6010/0/0/67 (baseline 5982/0/0/67); PIT 15/15. No Flyway migration.

✅ **Post-deploy probe PASSED on dev 2026-09-01** as `panderson` (script:
`sbdocs/9-System/scripts/probe-wms2-sdr-cache-eviction-dev.sh`, PW is the dev password). `GET
/v3/system/mobileUiUrl` → PATCH sysprop 129 → GET returned the NEW value; pre-fix it returned the
stale one. Reverted; DB verified byte-identical, `version` 2→4, zero stray markers.

**A PASS there is self-certifying** — pre-merge code cannot produce it — so it closed the container
half in one observation: eviction fires in the deployed container, the bean IS created and registered
(the gap no unit test could reach), and the new build IS deployed. `sysprops` is the ONLY
confound-free live instrument: 159 rows < 200 entries, whereas clients (156/100), locations
(2749/2000) and itemdata (8805/3000) are over-subscribed, so a probe there can go green on capacity
eviction alone. **Ready to archive.**

## The defect

SDR writes run through `RepositoryEntityController`, which carries **no `@CacheEvict`** — so no
annotation anywhere in the app can observe them. Measured on dev as an ordinary `wms_user`:
`PATCH /v3/sysprop/129` → 200, DB changed, `GET /v3/system/mobileUiUrl` kept serving the old value.
`PutawayConfigRepositoryEventHandler` does hook SDR writes for three of the four entities, but every
eviction on it sits behind a **putaway-delta early return**, and it has no `Location` methods at all.
Sibling of SBDEV-3135 (PR #250), which closed the MVC/service half.

## Three things that are NOT obvious and cost real work to find

**1. `@Order(Ordered.HIGHEST_PRECEDENCE)` on every handler method is REQUIRED, not stylistic.**
`AnnotatedEventHandlerInvoker.onApplicationEvent` (spring-data-rest-core 4.5.7) dispatches through a
**bare `for` loop with no try/catch**, over a list sorted by `AnnotationAwareOrderComparator` applied to
the **method**. A sibling handler method that throws **aborts dispatch**, and everything after it
silently never runs — and `PutawayConfigRepositoryEventHandler.onAfterSave(Sysprop)` does a
transactional DB write. Without ordering, an audit failure silently disables cache coherence with no
trace. Two bounds worth knowing: `Collections.sort` is **stable**, so two siblings both at
`HIGHEST_PRECEDENCE` order by *bean-creation order*; and `@Order` orders only **within** the invoker,
not against `ValidatingRepositoryEventListener`, a second `ApplicationListener<RepositoryEvent>`.

**2. 🔴 `RepositorySearchController` publishes NO repository event.** Searching all of
spring-data-rest-webmvc 4.5.7 for `publishEvent` finds it in exactly two classes —
`RepositoryEntityController` and `RepositoryPropertyReferenceController`. So an **SDR-exported
`@Modifying` query** mutates rows at `GET /v3/<res>/search/{path}` and **no `@HandleAfter*` method can
ever see it**, however many you declare. Two on `ClientRepository`:
`toggleEnableReceivingById` (no in-process caller at all) and `updatePrinterToNullByPrinterId`. Fixed
with `@CacheEvict` on the **repository methods** — which also closed a separate finding, since
`PrinterController.deletePrinter` is the latter's only in-process caller and carried no eviction, so
deleting a printer left its id in every cached `Client` for up to the TTL.
⚠ This rests on `@CacheEvict` being honoured on an **interface** method — true, but test it (AC-28),
because if it were false both annotations would be a silent permanent no-op.

**3. `clear()`, not key-scoped** — an SDR PATCH can rename the field the cache is keyed on
(`LocationService.getByName` on the name, `ClientService.getByNumber` on `clNr`), so a key-scoped evict
clears the new key and orphans the old. And **twelve methods over four CONCRETE types**, never one over
`AbstractBaseEntity`: dispatch filters with `ClassUtils.isAssignable`, so a base-typed method would
clear a cache on every SDR domain type in the app.

## Facts measured here, reusable

- **Events fire AFTER commit**: `spring.jpa.open-in-view=false`, no `@Transactional` on
  `RepositoryEntityController` or any filter, `SimpleJpaRepository.save` carries its own. Residual is a
  one-round-trip read-through re-warm. ⚠ **Inverts if OSIV is ever enabled** — now pinned by a test
  (AC-27) rather than left as prose.
- **`clear()` is JVM-LOCAL** under the default `@Profile("!redis")` Caffeine manager, so on
  multi-replica the residual is the **full 2–5 min TTL** on every replica that did not serve the write.
  Bounds every eviction in the app. The `redis` profile exists for this and is enabled **nowhere**.
- **Do not add `TransactionAwareCacheManagerProxy`.** Its `clear()` is a **pass-through** with no
  synchronization active (not a no-op, as I first wrote), so it buys nothing here — and where a
  transaction IS active it re-times every existing in-transaction `@CacheEvict` in the app.
- **Cache size vs population on `dev_wh01_om1`**: clients 100/156, locations 2000/2749, itemdata
  3000/8805 — all over-subscribed — but **sysprops 200/159 is NOT**. That asymmetry decides which
  entity a live staleness probe can be run against: for the three over-subscribed ones a probe can go
  green because **capacity eviction** dropped the entry. Caffeine is Window-TinyLFU, so an entry read
  once can be dropped after a handful of distinct reads, not ~100. Clean live instrument if needed:
  `GET /actuator/metrics/cache.evictions?tag=cache:<name>` requiring delta 0 — Caffeine's
  `evictionCount()` excludes manual invalidations while `SIZE`/`EXPIRED` count, and
  `CaffeineCache.clear()` is `invalidateAll()`.
- **Redis `clear()` is `KEYS` + `DEL`**, not `SCAN` — `RedisCacheManager.builder` yields a non-locking
  writer using `BatchStrategies.keys()`.
- **The container half IS provable, contrary to what I first wrote.** `putaway_config_audit` on dev
  holds one `hal` row; `CHANNEL_HAL` is written at exactly one site, reachable only from
  `PutawayConfigRepositoryEventHandler`'s `@HandleAfter*` methods. So a deployed container demonstrably
  post-processes a `@Component @RepositoryEventHandler` in `net.aim_ai.wms.config` and dispatches to it.

## Left open

- Post-deploy: re-run the sysprop probe on dev — the one confound-free live instrument, and it
  exercises the real SDR route and container registration together.
- The `Itemdata` handler methods are dead today (`Itemdata` is in `SDR_WRITE_WITHDRAWN`, PATCH → 405)
  and kept deliberately: that list is a mutable array and `SdrWriteWithdrawalContextTest` pins the
  **list**, not the cache consequence of editing it.

Related: [[a-guard-fences-the-mechanism-you-aimed-at]] (the pattern, twice: the putaway handler's
early returns, then my own scoping to the entity controller),
[[wms2-src-wide-scans-also-pick-up-test-classes]] (hit twice while doing this),
[[mutation-harness-traps]], [[green-tests-that-prove-nothing]],
[[wms2-client-without-section-silently-stalls-pickpack]] (why a stale `Client` matters),
[[wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway]].
