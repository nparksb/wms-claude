# SBDEV-3176 — architect consult: a separate `@RepositoryEventHandler` for SDR cache eviction

- **Date:** 2026-09-01
- **Repo state:** `origin/develop` @ `92ca2e38` (`Merge pull request #260 from SiteBossInc/bugfix/SBDEV-3175-landlord-password-env-var`)
- **Scope:** four sub-questions only. The agreed fix (a new, separate handler bean; `clear()` not key-scoped; verb withdrawal off the table) is taken as settled.
- **Citation rule used here:** every claim carries a `file` (repo-relative or absolute jar path) plus the quoted text it rests on. Line numbers appear only as a navigation aid alongside a quote.

---

## Verified inputs (independent confirmation of the given facts)

I re-derived the two numeric premises rather than accept them, because Q4 turns on them.

`mcp__wms2-wineco-dev__execute_sql` against `dev_wh01_om1`:

```
db=dev_wh01_om1  clients=156  locations=2749  sysprops=159  itemdata=8805
```

Against `v2/wms2-api/src/main/java/net/aim_ai/wms/config/CacheConfig.java`:

```java
buildCaffeineCache("sysprops", 200, Duration.ofMinutes(2)),
buildCaffeineCache("clients", 100, Duration.ofMinutes(5)),
buildCaffeineCache("locations", 2000, Duration.ofMinutes(5)),
buildCaffeineCache("itemdata", 3000, Duration.ofMinutes(5))
```

| cache | maxSize | rows on `dev_wh01_om1` | over capacity? |
|---|---|---|---|
| `sysprops` | 200 | 159 | **no** |
| `clients` | 100 | 156 | **yes** |
| `locations` | 2000 | 2749 | **yes** |
| `itemdata` | 3000 | 8805 | **yes** |

`sysprops` being *under* capacity is the reason the 2026-08-31 live sysprop measurement is trustworthy. It is also why that measurement does **not** license the same probe shape for `clients`/`locations` (Q4).

All four entities share a base class — `git show origin/develop:src/main/java/net/aim_ai/wms/model/{Client,Location,Sysprop,Itemdata}.java`:

```java
public class Client extends AbstractBaseEntity {
public class Location extends AbstractBaseEntity {
public class Sysprop extends AbstractBaseEntity {
public class Itemdata extends AbstractBaseEntity {
```

This matters in Q1.

---

## Q1 — Is a separate `@RepositoryEventHandler` bean the right seam?

### Verdict: **Yes, and the jar confirms append semantics.** Two real hazards, both cheap to close.

### A. Handler methods are APPENDED across beans; nothing "wins"

Jar: `/home/nampark/.m2/repository/org/springframework/data/spring-data-rest-core/4.5.7/spring-data-rest-core-4.5.7-sources.jar`
File: `org/springframework/data/rest/core/event/AnnotatedEventHandlerInvoker.java`

The registry is a **multi**-valued map, not a map of one handler per event:

```java
private final MultiValueMap<Class<? extends RepositoryEvent>, EventHandlerMethod> handlerMethods
        = new LinkedMultiValueMap<Class<? extends RepositoryEvent>, EventHandlerMethod>();
```

`inspect(...)` — the registration path — **only ever adds** (line ~146):

```java
List<EventHandlerMethod> events = handlerMethods.get(eventType);

if (events == null) {
    events = new ArrayList<EventHandlerMethod>();
}

if (events.isEmpty()) {
    handlerMethods.add(eventType, handlerMethod);
    return;
}

events.add(handlerMethod);
Collections.sort(events);
handlerMethods.put(eventType, events);
```

There is no `remove`, no `putIfAbsent`, no keying by domain type. The `put` at the end writes back the very same live `List` instance the `get` returned.

Dispatch iterates **all** registered methods and filters by the declared first-parameter type (line ~57):

```java
for (EventHandlerMethod handlerMethod : handlerMethods.get(eventType)) {
    Object src = event.getSource();
    if (!ClassUtils.isAssignable(handlerMethod.targetType, src.getClass())) {
        continue;
    }
    ...
    ReflectionUtils.invokeMethod(handlerMethod.method, handlerMethod.handler, parameters.toArray());
}
```

And discovery is **per bean**, via `BeanPostProcessor`:

```java
public Object postProcessAfterInitialization(final Object bean, String beanName) throws BeansException {
    Class<?> beanType = ProxyUtils.getUserClass(bean);
    RepositoryEventHandler typeAnno = AnnotationUtils.findAnnotation(beanType, RepositoryEventHandler.class);
    if (typeAnno == null) { return bean; }
    for (Method method : ReflectionUtils.getUniqueDeclaredMethods(beanType)) { ... }
```

**Conclusion:** a second `@RepositoryEventHandler` bean declaring `@HandleAfterSave void x(Sysprop s)` coexists with `PutawayConfigRepositoryEventHandler.onAfterSave(Sysprop)`. Both fire. The existing bean is untouched. This is exactly the seam the agreed fix assumes.

### B. The "will it even register?" objection is already answered by the jar

The existing handler's own javadoc raises this objection (`v2/wms2-api/src/main/java/net/aim_ai/wms/config/PutawayConfigRepositoryEventHandler.java`, the SBDEV-3169 F1 block):

> "A second `@RepositoryEventHandler` for the same entity would be tidier and would need its own evidence that it fires at all — and an authorization fence that silently does not run is the exact failure this programme keeps finding."

The structural risk behind that objection is the classic BPP-ordering trap: a bean created *before* the `BeanPostProcessor` registry is complete never gets post-processed. That trap is **closed by SDR itself**. Jar `spring-data-rest-webmvc-4.5.7-sources.jar`, file `org/springframework/data/rest/webmvc/config/RepositoryRestMvcConfiguration.java` (line ~409):

```java
@Bean
public static AnnotatedEventHandlerInvoker annotatedEventHandlerInvoker() {
    return new AnnotatedEventHandlerInvoker();
}
```

The `static` is load-bearing: a static `@Bean` BPP is instantiated during `registerBeanPostProcessors`, ahead of ordinary singletons. A plain `@Component` handler whose only dependency is `CacheManager` is created in the regular singleton phase and *will* be post-processed — the same phase in which `PutawayConfigRepositoryEventHandler` (a `@Component` taking one service) is already proven to register.

**That is an argument, not evidence.** See §D for the instrument that turns it into evidence.

### C. Hazard 1 — ordering, and it is not cosmetic

`EventHandlerMethod.compareTo` sorts on the **method**, not the bean:

```java
@Override
public int compareTo(EventHandlerMethod o) {
    return AnnotationAwareOrderComparator.INSTANCE.compare(this.method, o.method);
}
```

Jar `/home/nampark/.m2/repository/org/springframework/spring-core/6.2.15/spring-core-6.2.15-sources.jar`, `org/springframework/core/annotation/AnnotationAwareOrderComparator.java`:

```java
private Integer findOrderFromAnnotation(Object obj) {
    AnnotatedElement element = (obj instanceof AnnotatedElement ae ? ae : obj.getClass());
```

`java.lang.reflect.Method` **is** an `AnnotatedElement`, so `@Order` placed on the *handler method* is honoured. `@Order` on the handler *class* is **not** consulted on this path.

Why the order matters: dispatch calls `ReflectionUtils.invokeMethod(...)` in a bare `for` loop with **no try/catch**. An exception thrown by the first handler aborts the loop and the remaining handlers never run. The existing after-handlers can throw — they perform DB writes:

```java
@HandleAfterSave
public void onAfterSave(Sysprop saved) {
    ...
    putawayConfigService.auditAndEvictWarehouse(saved.getId(), pending.previous(), newDestination);
}
```

With neither method annotated, both resolve to `LOWEST_PRECEDENCE`, `compare` returns 0, `Collections.sort` is stable, and the surviving order is bean-creation order — which is not something the fix should depend on.

**Recommendation:** annotate **every** method of the new handler `@Order(Ordered.HIGHEST_PRECEDENCE)`. Cost: one annotation per method. Benefit: cache eviction can never be starved by a putaway audit failure, deterministically. (Note the sort is global per event type, so this also orders the new methods ahead of the putaway methods for *other* domain types — harmless, they are filtered out by `isAssignable`.)

### D. Hazard 2 — declare CONCRETE types, never `AbstractBaseEntity`

Because dispatch filters with `ClassUtils.isAssignable(handlerMethod.targetType, src.getClass())` and all four entities `extends AbstractBaseEntity`, a single tidy-looking method

```java
@HandleAfterSave void onAfterSave(AbstractBaseEntity e)   // DO NOT
```

would fire on **every** SDR-exported domain type in the app, clearing all four caches on every SDR write anywhere. Declare four concrete overloads per event annotation (`Client`, `Location`, `Sysprop`, `Itemdata`) — 12 methods total. There is no shortcut here that is safe.

### E. The evidence the existing javadoc demands

`PutawayResolverContextLoadTest` is **not** that evidence — it asserts only bean presence:

```java
assertThat(putawayConfigRepositoryEventHandler).isNotNull();
```

A bean can exist and still have registered zero handler methods.

The cheap, deterministic instrument is to drive the **real** SDR invoker in a unit test — `AnnotatedEventHandlerInvoker` is public with a public no-arg constructor and both entry points (`postProcessAfterInitialization`, `onApplicationEvent`) are public:

1. `var invoker = new AnnotatedEventHandlerInvoker();`
2. `invoker.postProcessAfterInitialization(putawayHandler, "putaway...");`
3. `invoker.postProcessAfterInitialization(newCacheHandler, "sdrCache...");`
4. `invoker.onApplicationEvent(new AfterSaveEvent(sysprop));`
5. assert **both** ran (the cache entry is gone **and** the putaway audit was invoked).

This pins append-semantics, both-fire, and `@Order` in one test, with no Spring context and no Testcontainers. Run it with the handlers registered in *both* orders to prove order-independence of the outcome.

**Residual gap I cannot close from the code alone:** this proves the invoker's contract, not that the container hands *this* bean to *that* invoker at runtime. The strongest available cheap check for the container half is a startup assertion or a `@SpringBootTest` reflecting on the invoker's `handlerMethods`; given SBDEV-2217 the `@SpringBootTest` lane may be unavailable. State the container half as "same instantiation phase as the already-proven `PutawayConfigRepositoryEventHandler`" and back it with the live dev probe (Q4), rather than claiming it is unit-proven.

---

## Q2 — Transaction-commit ordering

### Verdict: **The After events fire AFTER commit on this app's configuration. The pre-commit re-warm race in the question does not exist here.** Recommended action: document the (different, unavoidable) residual window and change nothing else. Explicitly do **not** introduce `TransactionAwareCacheManagerProxy` — it is provably a no-op on this path and a global semantic change everywhere else.

### The chain, link by link

**1. No outer transaction from OSIV.** `v2/wms2-api/src/main/resources/application.properties`:

```
spring.jpa.open-in-view=false
```

(`git grep -n "open-in-view" origin/develop -- 'src/main/resources/application*.properties'` returns exactly this one line; there is no profile-specific override in the repo.)

**2. No outer transaction from the controller or from a filter/interceptor.** `RepositoryEntityController.java` (in `spring-data-rest-webmvc-4.5.7-sources.jar`) carries no `@Transactional` — `grep -n "@Transactional"` on that file returns nothing. In the app, `git grep -ln "Transactional" origin/develop -- 'src/main/java/net/aim_ai/wms/landlord/**' 'src/main/java/net/aim_ai/wms/security/**' 'src/main/java/net/aim_ai/wms/RestConfiguration.java'` returns only `landlord/service/LandlordService.java` — no filter, no interceptor, no SDR config class opens a request-scoped transaction.

**3. The publish sites straddle the repository call, not a transaction.** `RepositoryEntityController.java`:

```java
private ResponseEntity<RepresentationModel<?>> saveAndReturn(Object domainObject, RepositoryInvoker invoker, ...) {
    publisher.publishEvent(new BeforeSaveEvent(domainObject));
    Object obj = invoker.invokeSave(domainObject);
    publisher.publishEvent(new AfterSaveEvent(obj));
```

```java
    publisher.publishEvent(new BeforeCreateEvent(domainObject));
    Object savedObject = invoker.invokeSave(domainObject);
    publisher.publishEvent(new AfterCreateEvent(savedObject));
```

```java
    publisher.publishEvent(new BeforeDeleteEvent(it));
    invoker.invokeDeleteById(entity.getIdentifierAccessor(it).getIdentifier());
    publisher.publishEvent(new AfterDeleteEvent(it));
```

**4. The transaction begins and ends *inside* `invokeSave` / `invokeDeleteById`.** Jar `/home/nampark/.m2/repository/org/springframework/data/spring-data-jpa/3.5.7/spring-data-jpa-3.5.7-sources.jar`, `org/springframework/data/jpa/repository/support/SimpleJpaRepository.java`:

```java
@Repository
@Transactional(readOnly = true)
public class SimpleJpaRepository<T, ID> implements JpaRepositoryImplementation<T, ID> {
```

```java
@Override
@Transactional
public <S extends T> S save(S entity) {
```

**5. That advice is active in this app.** `v2/wms2-api/src/main/java/net/aim_ai/wms/landlord/config/TenantDatabaseConfig.java`:

```java
@EnableJpaRepositories(
    basePackages = "net.aim_ai.wms.repo.jpa",
    entityManagerFactoryRef = "tenantEntityManagerFactory",
    transactionManagerRef = "tenantTransactionManager"
)
```

`enableDefaultTransactions` is not set, so it keeps its `true` default and `SimpleJpaRepository`'s own `@Transactional` governs.

**Therefore:** each SDR write opens its own transaction inside `invokeSave`/`invokeDeleteById` and **commits before that call returns**. `publishEvent(new AfterSaveEvent(...))` executes on a thread with no active transaction. `@HandleAfterSave` / `AfterCreate` / `AfterDelete` run **post-commit**. The premise "a concurrent read can re-warm the cache from pre-commit state" is false for this configuration.

### What the residual window actually is (it is not zero)

A different, smaller race survives, and no evict-after-write scheme can remove it:

> Reader R issues `getByKey(k)`, misses, and starts its SELECT. Writer W commits, then `clear()`s. R's SELECT — which read the pre-commit snapshot — returns and `@Cacheable` **stores the stale value after the clear**.

Window ≈ one query round-trip (single-digit ms), versus the 2–5 minute TTL that the bug currently sustains. It is inherent to read-through caching without versioned writes; `TransactionAwareCacheManagerProxy` does not address it either.

### Why NOT `TransactionAwareCacheManagerProxy` — two independent reasons

**(a) It would be a literal no-op here.** Jar `/home/nampark/.m2/repository/org/springframework/spring-context-support/6.2.15/spring-context-support-6.2.15-sources.jar`, `org/springframework/cache/transaction/TransactionAwareCacheDecorator.java`:

```java
public void clear() {
    if (TransactionSynchronizationManager.isSynchronizationActive()) {
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public void afterCommit() {
                targetCache.clear();
            }
        });
    }
    else {
        this.targetCache.clear();
    }
}
```

No synchronization is active when the After handler runs (§ chain above), so it takes the `else` branch — behaviour identical to a plain `clear()`. Zero benefit, non-zero code.

**(b) It is a global change, not a local one.** The proxy wraps the app's single `CacheManager` bean, so it re-times **every** existing eviction. `git grep -c "@CacheEvict" origin/develop -- 'src/main/**'` returns 40 textual occurrences across 10 files (a few are javadoc references). Several are real annotations sitting directly on `@Transactional` methods — e.g. `v2/wms2-api/src/main/java/net/aim_ai/wms/service/LocationService.java`:

```java
@CacheEvict(value = "locations", allEntries = true)
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public Location updateLocation(Location location) throws BusinessException {
```

Today those evict *immediately*; under the proxy they would evict *after commit*. Re-timing ~dozens of eviction sites is not a T2 change, and nothing in SBDEV-3176 asks for it.

**Recommendation:** add a short javadoc paragraph on the new handler recording (i) that After events are post-commit here and why, (ii) the one-round-trip re-warm residual, and (iii) that `TransactionAwareCacheManagerProxy` was considered and rejected with the two reasons above. That matches how every other eviction in this codebase is documented and costs nothing.

⚠ **Regression tripwire worth writing into the doc:** the post-commit property depends entirely on there being no outer transaction. If anyone later sets `spring.jpa.open-in-view=true` with a transaction, or wraps an SDR path in `@Transactional`, the ordering inverts silently and the fix degrades without any test going red.

---

## Q3 — `clear()` blast radius across tenants

### Verdict: **Use `clear()`. Do not scope by key prefix.** The cross-tenant cost is *zero on prd and zero on dev today*, four routing keys on UAT, and it is bounded by caches that already cannot hold one tenant's working set.

### The blast radius is measured, not assumed

Landlord DBs, queried live 2026-09-01:

`mcp__landlord-prd__execute_sql` — `current_database() = wms2_landlord`:

```
tenant=hydra  warehouse=nywh  active=True  db=wh01_hydra_v2
```

**One row. Production serves exactly one routing key.**

`mcp__landlord-dev__execute_sql` — `current_database() = dev_landlord`:

```
hydra    / nywh / active=False / wh01_hydra_v2
shipitez / c1wh / active=False / wh02_hydra
shipitez / nywh / active=False / wh01_hydra
wineco   / wsl  / active=True  / dev_wh01_om1
```

**One active row.**

`mcp__landlord-uat__execute_sql` — `current_database() = landlord`:

```
hydra    / nywh / active=True / wh01_hydra_v2
shipitez / c1wh / active=True / wh01_shipitez_v2
shipitez / nywh / active=True / wh02_shipitez_v2
wineco   / wsl  / active=True / wh01_om1_v2
```

**Four active routing keys — UAT is the only genuinely multi-tenant JVM today.**

Only active configurations enter the routing cache. `v2/wms2-api/src/main/java/net/aim_ai/wms/landlord/jpa/TenantDbConfigurationRepository.java`:

```java
// SBDEV-2727 — only active tenant DB configurations (excludes deactivated tenants)
```

and `v2/wms2-api/src/main/java/net/aim_ai/wms/landlord/config/TenantConfigLoader.java`:

```java
// SBDEV-2727: also evict any live pool whose key vanished from the active-filtered
```

So the shared-cache concern is real in principle and, on prd/dev, currently vacuous.

### Four further reasons `clear()` wins even on UAT

1. **These caches are already thrashing.** `clients` holds 100 of one tenant's 156 rows; `locations` holds 2000 of 2749. A cache that cannot retain a single tenant's working set is not one whose *cross-tenant* retention is worth engineering for — the entries a prefix-scoped clear would preserve have a hit probability capacity pressure is already eroding.
2. **The write frequency is administrative.** `/v3/client`, `/v3/location`, `/v3/sysprop` are admin-console configuration writes, not order-flow traffic. A full clear costs one cold-read burst per configuration edit.
3. **The service layer already does exactly this, deliberately.** `v2/wms2-api/src/main/java/net/aim_ai/wms/service/LocationService.java`:

   ```java
   // SBDEV-3135: allEntries is REQUIRED here, not merely consistent with the siblings. This method
   // can RENAME a location, while the @Cacheable getByName is keyed on the NAME — so a key-scoped
   // evict (key = "...#location.name") would clear only the new name and leave the OLD name still
   // resolving to a location that no longer answers to it. Pinned by
   // CacheEvictionOnWriteUnitTest.updateLocation_shouldEvictOldName_whenLocationRenamed, which
   // renames deliberately so a key-scoped variant cannot pass it.
   @CacheEvict(value = "locations", allEntries = true)
   ```

   A key-scoped SDR handler would be *strictly weaker* than the eviction the same cache already receives from the service path, for the identical rename reason. That is an inconsistency with no upside.
4. **A prefix-scoped clear is not expressible through the `Cache` SPI.** `org.springframework.cache.Cache` offers `evict(key)` and `clear()` — no key enumeration. Prefix scoping would require `((CaffeineCache) cache).getNativeCache().asMap().keySet()`, hard-coupling the handler to Caffeine and breaking under the `redis` profile, or a per-manager branch. New surface, zero measured benefit.

### Correction to the premise: under `redis`, `clear()` is KEYS + DEL, not SCAN + DEL — and worse than stated

`v2/wms2-api/src/main/java/net/aim_ai/wms/config/CacheConfig.java` builds the Redis manager with the default writer:

```java
return RedisCacheManager.builder(connectionFactory)
```

Jar `/home/nampark/.m2/repository/org/springframework/data/spring-data-redis/3.5.7/spring-data-redis-3.5.7-sources.jar`, `org/springframework/data/redis/cache/RedisCacheManager.java`:

```java
public static RedisCacheManagerBuilder fromConnectionFactory(RedisConnectionFactory connectionFactory) {
    ...
    RedisCacheWriter cacheWriter = RedisCacheWriter.nonLockingRedisCacheWriter(connectionFactory);
```

and `org/springframework/data/redis/cache/RedisCacheWriter.java`:

```java
static RedisCacheWriter nonLockingRedisCacheWriter(RedisConnectionFactory connectionFactory) {
    return nonLockingRedisCacheWriter(connectionFactory, BatchStrategies.keys());
}
```

`org/springframework/data/redis/cache/BatchStrategies.java`:

> "A `BatchStrategy` using a single `KEYS` and `DEL` command to remove all matching keys. `KEYS` scans the entire keyspace of the Redis database and can block the Redis worker thread for a long time"

So the hypothetical Redis cost is a **blocking `KEYS` over the whole keyspace**, not an incremental `SCAN`.

**This is latent, not live.** The `redis` profile is activated nowhere in the repo — `v2/wms2-api/src/main/resources/application.properties` line 22 reads `# Activate with: spring.profiles.active=redis`, and the only profile line in `Dockerfile` is commented out: `#ENV SPRING_PROFILES_ACTIVE=wineco`.

**Definite recommendation:** ship `clear()`. Additionally, put a two-line note in the new handler's javadoc: *if the `redis` profile is ever enabled, `CacheConfig.redisCacheManager` must first switch its cache writer to `BatchStrategies.scan(n)`, because `clear()` there is a blocking `KEYS`.* That is a separate ticket, not SBDEV-3176.

---

## Q4 — Does capacity eviction threaten a live dev probe?

### Verdict: **Yes, genuinely, for `clients` and `locations` — and not at all for `sysprops`.** The primary instrument must be a JUnit test on an unbounded, non-expiring cache; a live probe is admissible only as a second instrument, and only with the eviction counter read on both sides.

### The threat is real and asymmetric

- `sysprops`: 159 rows < 200 slots → the cache can hold every row → capacity eviction is **structurally impossible**. The 2026-08-31 live sysprop measurement is sound, and remains sound as the live re-probe subject.
- `clients`: 156 rows > 100 slots → **over capacity**.
- `locations`: 2749 rows > 2000 slots → **over capacity**.
- `itemdata`: 8805 rows > 3000 slots → grossly over (moot today; SDR verbs withdrawn).

It threatens the probe in **both** directions, and the second is the more damaging:

1. **False PASS after the fix** — the entry was dropped for capacity, so the reader hits the DB whether or not the handler ran.
2. **Loss of the negative control before the fix** — you cannot reliably demonstrate the stale read, so there is nothing for the post-fix result to be compared against. A probe that cannot fail pre-fix proves nothing post-fix.

Two aggravating factors:

- **`expireAfterWrite` is a second clock-shaped confound** — 5 min for `clients`/`locations`, 2 min for `sysprops`. A hand-driven probe can easily straddle it.
- **Caffeine is Window-TinyLFU, not LRU.** `buildCaffeineCache` uses `Caffeine.newBuilder().maximumSize(maxSize)`, whose eviction admits candidates by frequency. A once-read entry can be rejected at admission and dropped after a *handful* of subsequent distinct reads — not after ~100. The "you'd need 100 other client reads" intuition is wrong and unsafe to rely on. *(I did not measure the admission-window size for this configuration; the point stands as "the drop point is far earlier than N and is not predictable from outside", not as a specific number.)*

### How the test must be designed so a pass cannot come from capacity eviction

**Primary instrument — extend the harness this codebase already built for exactly this.** `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/config/CacheEvictionOnWriteUnitTest.java` states the design rule in its own javadoc:

> "**No TTL, deliberately.** Production caches expire after five minutes (`CacheConfig.buildCaffeineCache` uses `expireAfterWrite`, so that bound is hard). `ConcurrentMapCacheManager` never expires, which is the correct harness: the defect is what a caller observes *inside* the window, and a test that could pass by waiting would be measuring the clock rather than the eviction."

`ConcurrentMapCacheManager` is also **unbounded**, so capacity eviction is structurally impossible in the harness — it removes both confounds at once. The same javadoc gives the design rationale for behaviour-over-annotation:

> "An assertion that the annotation is *present* proves only that a character sequence exists — it cannot distinguish an evict that fires from one whose key expression clears the wrong entry, and it goes green against a class Spring never proxies."

Concretely, for each of `Client`, `Location`, `Sysprop`:

1. Build the `@EnableCaching` context with `ConcurrentMapCacheManager` (unbounded, no TTL).
2. **Warm through the real `@Cacheable` reader** — `ClientService.getByNumber`, `LocationService.getByName`, `SyspropService.getByKey`/`getSysvalue` — not by poking the cache directly.
3. **Fire the event through the real invoker**, not by calling the handler method: `new AnnotatedEventHandlerInvoker()` → `postProcessAfterInitialization` on both handler beans → `onApplicationEvent(new AfterSaveEvent(entity))`. Calling the handler method directly would prove the method body and not that SDR reaches it — the very gap §Q1.E exists to close.
4. Assert the reader now returns the **new** value, with the repository stub verified to have been consulted a second time.
5. **Include a rename/renumber case** (`Location.name`, `Client.clNr`) — the case that a key-scoped variant cannot pass, mirroring `updateLocation_shouldEvictOldName_whenLocationRenamed`.
6. **Mutation-check each assertion**: delete the `clear()` and confirm RED; then delete the `@Order` and confirm the both-fire test still passes for the right reason.

⚠ **The vacuity trap this specific harness has already been caught by, twice.** Its javadoc:

> "**⚠ ALIASING is how a harness like this goes vacuous — every stub answers with a FRESH instance.** ... If the cached reader and the writer are handed the SAME entity object, the writer mutates the very instance sitting in the cache and an assertion about 'the cache is stale' passes with no eviction anywhere. Measured twice on this class: `toggleReceiving`'s eviction could be deleted with all tests green..."

Every stub in the new tests must build a fresh instance per call.

**Second instrument — a live dev probe, made capacity-proof by measurement rather than by assumption.**

- Prefer `sysprops` as the live subject: capacity eviction is structurally impossible there (159 < 200), which is why it is the one dataset where a live PATCH-then-read is self-evidently valid.
- If `clients`/`locations` must be probed live, **read the eviction counter immediately before and after the probe and require a delta of 0**:

  ```
  GET http://<dev-host>:8088/actuator/metrics/cache.evictions?tag=cache:clients
  GET http://<dev-host>:8088/actuator/metrics/cache.size?tag=cache:clients
  ```

  A `cache.size` strictly below `maxSize` additionally proves the cache was never full, so capacity eviction *cannot* have occurred.

**Why that counter is available and why it is exactly the right instrument** — four links, all verified:

1. Actuator + Prometheus are on the tree (`v2/wms2-api/pom.xml`: `spring-boot-starter-actuator`, `micrometer-registry-prometheus`) and `metrics` is exposed — `application.properties`: `management.endpoints.web.exposure.include=health,info,metrics,hikaricp,prometheus,tenantpool` on `management.server.port=8088`. (`caches` is **not** exposed, so no accidental clear-via-actuator.)
2. The app's hand-rolled `CacheManager` is still bound. Jar `spring-boot-actuator-autoconfigure-3.5.9-sources.jar`, `CacheMetricsAutoConfiguration.java`: `@ConditionalOnBean(CacheManager.class)` — satisfied by `caffeineCacheManager` even though `CacheAutoConfiguration` backs off; and `CacheMetricsRegistrarConfiguration.java` collects **every** manager: `this.cacheManagers = SimpleAutowireCandidateResolver.resolveAutowireCandidates(beanFactory, CacheManager.class);` then `cacheManager.getCacheNames().forEach(...)`. `CaffeineCacheMeterBinderProvider` is registered under `@ConditionalOnClass({ CaffeineCache.class, com.github.benmanes.caffeine.cache.Cache.class })`. Stats are on — `buildCaffeineCache` calls `.recordStats()`.
3. Micrometer emits the counter under that name. Jar `micrometer-core-1.15.7-sources.jar`, `CacheMeterBinder.java`: `FunctionCounter.builder("cache.evictions", cache, c -> {`.
4. **The counter excludes our fix and includes both confounds — this is the whole point.** Jar `caffeine-3.2.3-sources.jar`, `CacheStats.java`:

   > "Returns the number of times an entry has been evicted. **This count does not include manual `invalidations`.**"

   and `RemovalCause.java`:

   > "Returns `true` if there was an automatic removal due to eviction (the cause is neither `EXPLICIT` nor `REPLACED`)."

   `SIZE` and `EXPIRED` both return `true` from `wasEvicted()`; `EXPLICIT` returns `false`. And `CaffeineCache.clear()` (jar `spring-context-support-6.2.15-sources.jar`) is:

   ```java
   public void clear() {
       this.cache.invalidateAll();
   }
   ```

   — an `EXPLICIT` removal. **So `cache.evictions` counts capacity eviction and TTL expiry, and never counts the fix.** A zero delta across the probe window excludes both confounds by measurement.

**One caveat on the live probe, stated rather than glossed:** the dev deployment must be the build under test, and the counter is JVM-local — if dev ever runs more than one replica behind a load balancer, the two reads may land on different JVMs and the delta is meaningless. Confirm replica count = 1 before trusting it.

---

## Summary of concrete recommendations

| # | Recommendation | Effort | Impact |
|---|---|---|---|
| 1 | New `@Component @RepositoryEventHandler` bean; 12 methods over 4 **concrete** types × `AfterCreate`/`AfterSave`/`AfterDelete`; never `AbstractBaseEntity` | S | Correct seam; avoids clearing all caches on every SDR write app-wide |
| 2 | `@Order(Ordered.HIGHEST_PRECEDENCE)` on **every** method of the new bean | XS | Removes a nondeterministic ordering hazard: an exception from the putaway audit would otherwise starve eviction |
| 3 | Guarded `clear()` in the `evictSyspropKey` shape (null-manager WARN, null-cache WARN, `catch RuntimeException`) — reimplemented, since `SyspropService.evictSyspropKey` is `private` | XS | Eviction failure never escapes onto a write path |
| 4 | Prove registration with a unit test driving the real `AnnotatedEventHandlerInvoker` (both beans, both orders) | S | Closes the existing javadoc's explicit "would need its own evidence that it fires at all" objection |
| 5 | JUnit tests on `ConcurrentMapCacheManager` extending `CacheEvictionOnWriteUnitTest`; include a rename case; mutation-check each | M | Only harness in which capacity + TTL cannot manufacture a pass |
| 6 | Live re-probe on `sysprops`; for `clients`/`locations` require `cache.evictions` delta = 0 across the window | S | Turns "capacity did not interfere" from assumption into measurement |
| 7 | Javadoc: post-commit ordering + why, the one-round-trip residual, `TransactionAwareCacheManagerProxy` rejected (no-op here + global re-timing), and the redis `KEYS` note | S | Prevents the next reader from re-litigating, and flags the OSIV/`@Transactional` tripwire |

## Trade-offs

| Option | Pros | Cons |
|---|---|---|
| **`clear()` (recommended)** | Correct under rename/renumber; matches `LocationService`'s existing `allEntries=true`; expressible through the `Cache` SPI; zero cross-tenant cost on prd and dev today | Clears other tenants' entries on UAT (4 keys); under a future `redis` profile it is a blocking `KEYS` |
| Key-prefix-scoped clear | Preserves other tenants' entries | Not expressible via the `Cache` SPI → Caffeine coupling or a per-manager branch; weaker than the eviction the same cache already gets from `LocationService`; benefit is zero on prd/dev |
| `TransactionAwareCacheManagerProxy` | Would matter if the events fired pre-commit | They do not — `TransactionAwareCacheDecorator` takes the `else` branch with no active tx, so literally a no-op; and it re-times ~dozens of existing in-transaction `@CacheEvict` sites. Out of scope at T2 |
| Live dev probe as the primary instrument | End-to-end, exercises the real SDR route | Capacity eviction (`clients` 156>100, `locations` 2749>2000) + `expireAfterWrite` can manufacture a pass; W-TinyLFU makes the drop point unpredictable. Valid only for `sysprops`, or with the eviction counter pinned at 0 |

## References

- `/home/nampark/.m2/repository/org/springframework/data/spring-data-rest-core/4.5.7/spring-data-rest-core-4.5.7-sources.jar` → `org/springframework/data/rest/core/event/AnnotatedEventHandlerInvoker.java` — `LinkedMultiValueMap` registry; `inspect` appends; `onApplicationEvent` loops all matching methods with no try/catch; `compareTo` uses `AnnotationAwareOrderComparator` on the **method**
- `/home/nampark/.m2/repository/org/springframework/data/spring-data-rest-webmvc/4.5.7/spring-data-rest-webmvc-4.5.7-sources.jar` → `RepositoryEntityController.java` (publish sites straddling `invokeSave`/`invokeDeleteById`), `config/RepositoryRestMvcConfiguration.java` (`@Bean public static AnnotatedEventHandlerInvoker`)
- `/home/nampark/.m2/repository/org/springframework/data/spring-data-jpa/3.5.7/spring-data-jpa-3.5.7-sources.jar` → `SimpleJpaRepository.java` — `@Transactional` on `save`
- `/home/nampark/.m2/repository/org/springframework/spring-core/6.2.15/spring-core-6.2.15-sources.jar` → `AnnotationAwareOrderComparator.java` — `Method` is an `AnnotatedElement`
- `/home/nampark/.m2/repository/org/springframework/spring-context-support/6.2.15/spring-context-support-6.2.15-sources.jar` → `cache/transaction/TransactionAwareCacheDecorator.java` (`else` branch), `cache/caffeine/CaffeineCache.java` (`clear()` → `invalidateAll()`)
- `/home/nampark/.m2/repository/org/springframework/data/spring-data-redis/3.5.7/spring-data-redis-3.5.7-sources.jar` → `RedisCacheManager.java`, `RedisCacheWriter.java`, `BatchStrategies.java` — default writer is `BatchStrategies.keys()`
- `/home/nampark/.m2/repository/com/github/ben-manes/caffeine/caffeine/3.2.3/caffeine-3.2.3-sources.jar` → `stats/CacheStats.java`, `RemovalCause.java` — evictionCount excludes manual invalidation, includes SIZE and EXPIRED
- `/home/nampark/.m2/repository/io/micrometer/micrometer-core/1.15.7/micrometer-core-1.15.7-sources.jar` → `binder/cache/CacheMeterBinder.java` — `cache.evictions`
- `/home/nampark/.m2/repository/org/springframework/boot/spring-boot-actuator-autoconfigure/3.5.9/spring-boot-actuator-autoconfigure-3.5.9-sources.jar` → `metrics/cache/CacheMetricsAutoConfiguration.java`, `CacheMetricsRegistrarConfiguration.java`, `CacheMeterBinderProvidersConfiguration.java`
- `/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms/config/CacheConfig.java` — cache names, sizes, TTLs, both managers
- `/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms/config/PutawayConfigRepositoryEventHandler.java` — the only `@RepositoryEventHandler` in `src/main`; the "second handler would need its own evidence" javadoc; DB-writing After handlers
- `/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms/service/LocationService.java` — the existing `allEntries = true` rename rationale
- `/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms/service/SyspropService.java` — `private void evictSyspropKey` guarded shape
- `/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms/landlord/config/TenantDatabaseConfig.java` — `@EnableJpaRepositories(transactionManagerRef = "tenantTransactionManager")`
- `/home/nampark/dev/wms-claude/v2/wms2-api/src/main/resources/application.properties` — `spring.jpa.open-in-view=false`; actuator exposure; redis profile not activated
- `/home/nampark/dev/wms-claude/v2/wms2-api/src/test/java/net/aim_ai/wms/unit/config/CacheEvictionOnWriteUnitTest.java` — the harness precedent and its aliasing warning
- `/home/nampark/dev/wms-claude/v2/wms2-api/src/test/java/net/aim_ai/wms/smoke/PutawayResolverContextLoadTest.java` — asserts bean presence only; not registration evidence
- Live DB: `landlord-prd` (`wms2_landlord`, 1 tenant), `landlord-dev` (`dev_landlord`, 1 active of 4), `landlord-uat` (`landlord`, 4 active), `wms2-wineco-dev` (`dev_wh01_om1`: 156/2749/159/8805)
