# SBDEV-3176 — adversarial code review, lane A

**Commit:** `4d3000fd` "fix(cache): SBDEV-3176 — evict entity caches on Spring Data REST writes"
**Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/3176-review-a` (detached at `4d3000fd`)
**Reviewer:** cr-3176 (lane A) · 2026-09-01
**Baseline run:** `mvn -o test -Dtest='SdrCacheEviction*'` → **25/25 green**, 0 failures, 0 errors.
Worktree left clean (`git status --short` empty) after every mutation.

Counts: **1 High · 3 Medium · 7 Low.**

---

## Instruments used

| # | Instrument | What it settled |
|---|---|---|
| I-1 | `spring-data-rest-core-4.5.7-sources.jar`, `spring-data-rest-webmvc-4.5.7-sources.jar` (unzipped to scratch, read directly) | every `publishEvent` site; the dispatch loop; `ClassUtils.isAssignable`; `Collections.sort` |
| I-2 | `spring-context-support-6.2.15-sources.jar` | `TransactionAwareCacheDecorator.clear()` |
| I-3 | `spring-data-redis-3.5.7-sources.jar` | `BatchStrategies.Keys` = `KEYS` + `DEL`; `nonLockingRedisCacheWriter` default |
| I-4 | 5 source mutations, each compiled and run, each reverted (M1–M5 below) | test non-vacuity |
| I-5 | Live SQL — `landlord-prd`, `landlord-dev`, `landlord-uat`, `wms2-wineco-dev` MCP | every measured number in the javadoc |
| I-6 | `git grep` at `origin/develop` in `wms2-web-ui` / `wms2-mobile-ui` | caller enumeration for the gap in H-1 |

### Mutation log

| Mut | Change | Result | Verdict |
|---|---|---|---|
| **M1** | early-`return` before `cache.clear()` | **16/25 red**, each with its named `.as(...)` message | eviction assertions are real |
| **M2** | delete `@Order(Ordered.HIGHEST_PRECEDENCE)` from all 12 methods | **2 red** — AC-20 (behavioural) *and* AC-21 (annotation pin) | the `@Order` claim is behaviourally tested, not just asserted |
| **M3** | `SYSPROPS = "sysprops"` → `"sysprop"` | **6 red** across both classes | a cache-name typo in the handler IS caught |
| **M4** | comment out `@EnableCaching` on `CacheBase` | **exactly 4 red — AC-22, AC-23, AC-24, AC-25**; all 12 eviction tests stayed **green** | negative controls do precisely what they claim; **and the `@Configuration`→plain-`@Bean`-holder change did NOT disable `@EnableCaching`** |
| **M5** | `ClientHarness.row()` returns one SHARED instance mutated in place, **plus** M1 | **15 red, not 16** — the one test that flipped green is `Clients.save_shouldEvictClients` (AC-1) | the "freshly built instance per call" claim is **load-bearing and correct**: aliasing makes AC-1 pass against a handler that evicts nothing |

M4 and M5 are the two the brief asked me to prove by experiment. Both claims hold.

---

## HIGH

### H-1 · Two SDR-exported `@Modifying` query methods mutate `client` rows and publish no event — the twelve handlers cannot see them

`src/main/java/net/aim_ai/wms/repo/jpa/ClientRepository.java`:

```java
    @Modifying(clearAutomatically = true)
    @Transactional
    @RestResource(path = "toggleEnableReceivingById", rel = "toggleEnableReceivingById")
    @Query("UPDATE Client c SET c.enablereceiving = CASE WHEN c.enablereceiving = true THEN false ELSE true END WHERE c.id = :id")
    void toggleEnableReceivingById(@Param("id") Long id);
```

```java
    @Modifying(clearAutomatically = true)
    @Transactional
    @RestResource(path = "updatePrinterToNullByPrinterId", rel = "updatePrinterToNullByPrinterId")
    @Query("UPDATE Client c SET c.printerreceivingId = NULL WHERE c.printerreceivingId = :printerId")
    void updatePrinterToNullByPrinterId(@Param("printerId") Long printerId);
```

Both are exported (`@RepositoryRestResource` on the interface, `RepositoryDetectionStrategies.ANNOTATED`, explicit `@RestResource` paths), so they publish at `GET /v3/client/search/{path}`. **`RepositorySearchController` publishes no repository event at all** — grepping the whole of `spring-data-rest-webmvc-4.5.7` sources for `publishEvent` returns exactly 12 hits, 6 in `RepositoryEntityController` and 6 in `RepositoryPropertyReferenceController`, and none anywhere else. So no `AfterSaveEvent` fires and `clients` is not evicted.

This is not theoretical. The repo's own integration test drives the route:

`src/test/java/net/aim_ai/wms/integration/controller/ClientControllerLegacyIntegrationTest.java`
```java
                        get(this.urlBase + "/search/toggleEnableReceivingById")
                                .header("Authorization", this.bearer3L)
                                ...
                                .param("id", "0"))
                .andExpect(status().isOk());

        Client client2 = clientRepository.findById(9999L).get();
        assertEquals(client2.getEnablereceiving(), false);
```
`urlBase = "/v3/client"`. 200, row changed, no event.

**Failure scenario.** An operator flips a client's `enablereceiving` through this route (or an integration does). `ClientService.getByNumber` / `getSystemClient` keep serving the pre-toggle `Client` for up to the 5-minute `clients` TTL, on every replica. Same for a nulled `printerreceivingId`.

**What softens it:** I found no UI caller. `git grep toggleEnableReceivingById origin/develop` in both `wms2-web-ui` and `wms2-mobile-ui` returns nothing. But the search surface is ungated (`RestConfiguration`'s own javadoc: *"347 exported searches remain ungated reads"*), so any `wms_user` can reach it, and the route is a **mutating GET** — the class SBDEV-3155 spent a ticket on for the MVC side.

**What makes it High rather than Medium:** the commit subject and the class javadoc both assert the scope "Spring Data REST writes", and the javadoc's first sentence is a completeness claim — *"no annotation anywhere in this application can observe them"*. The fix leaves an SDR route that writes `client` and evicts nothing, and nothing in the change or its tests records that blind spot.

**Recommended fix.** Cheapest correct option: put `@CacheEvict(value = "clients", allEntries = true)` on the two repository methods (Spring's cache proxy does apply to repository interfaces), or — better, since the repo already prefers explicit mechanisms over annotations on SDR-reachable surfaces — withdraw the two from SDR with `@RestResource(exported = false)` (neither has an SDR caller; `updatePrinterToNullByPrinterId` has exactly one in-process caller, `PrinterController:168`) and let the MVC path own eviction. Whichever is chosen, add a sentence to the class javadoc naming `RepositorySearchController` as the one SDR controller that publishes no event, so the next reader does not have to re-derive it.

---

## MEDIUM

### M-1 · The `TransactionAwareCacheManagerProxy` justification is factually wrong

`SdrCacheEvictionEventHandler.java`, class javadoc:

> `{@code TransactionAwareCacheManagerProxy} is deliberately NOT introduced: with no synchronization active its {@code clear()} is a literal no-op, and it would re-time every existing in-transaction {@code @CacheEvict} in the application.`

The first half is false. `TransactionAwareCacheDecorator.clear()` (spring-context-support 6.2.15, the version on this classpath):

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

With no synchronization active it is a **direct pass-through**, not a no-op. `put` and `evict` have the identical shape.

**Failure scenario.** Not a runtime defect — a reasoning defect that will misdirect the next change. Someone who checks this sentence and finds it wrong has no way to tell whether the *decision* was also wrong, and the second reason (re-timing every existing `@CacheEvict`) is the one actually carrying it. This is a load-bearing design rationale in a file whose whole style is "the derivation is in the comment".

**Fix.** Delete the first clause. The honest version: *"with no synchronization active its `clear()` is a plain pass-through, so it would buy nothing on this path — and where a transaction IS active it would re-time every existing in-transaction `@CacheEvict` in the application."*

### M-2 · `PrinterController.deletePrinter` mutates `client` rows and evicts nothing (sibling of H-1, MVC side)

`src/main/java/net/aim_ai/wms/controller/PrinterController.java`:

```java
        // Set printerreceiving_id to NULL to avoid foreign key exception.
        clientRepository.updatePrinterToNullByPrinterId(printerId);
```

`grep -n "Cache" PrinterController.java` returns **nothing** — no `@CacheEvict` anywhere in the class. `ClientService.getByNumber` is `@Cacheable("clients")` and returns the whole `Client`, `printerreceivingId` included.

**Failure scenario.** Delete a printer; every cached `Client` that referenced it keeps reporting the deleted printer id for up to 5 minutes. Anything that resolves a receiving printer from a cached client gets a dangling id.

Strictly this is SBDEV-3135's territory (MVC/service side), not 3176's — but it is the direct sibling of H-1 (same repository method, other caller), and the repo's fix discipline requires the sibling sweep to be *reported* even when it is deferred. If it is not fixed here, it belongs on the SBDEV-3176 ticket as a note, because it is the second half of the same one-line finding.

**Fix.** `@CacheEvict(value = "clients", allEntries = true)` on `deletePrinter`, matching the four already on `ClientController`.

### M-3 · Caffeine `clear()` is JVM-local; the residual-window analysis omits the multi-replica case, which is far larger than the one it does state

`SdrCacheEvictionEventHandler.java`:

> `What remains is a read-through re-warm race of one round trip, which no evict-after-write scheme can close.`

That is true for a single JVM. But `CacheConfig.caffeineCacheManager` is the `@Profile("!redis")` bean, the handler's own javadoc records that the redis profile *"is activated in no environment today"*, and `CacheConfig`'s comment on the Redis bean says in as many words:

```java
     * Redis-backed cache for production multi-replica deployment.
     * Provides cross-replica cache consistency — @CacheEvict propagates to all instances.
```

So if more than one replica of wms2-api serves a tenant, an SDR write handled by replica A clears only A's Caffeine cache and replica B keeps serving stale reads for the full 2–5 minute TTL. The residual is the TTL, not one round trip.

I could not determine the replica count for prd from this worktree, so I am not claiming the fix is incomplete in production — I am claiming the javadoc enumerates residuals meticulously and silently omits the largest one. The same limit applies to every pre-existing `@CacheEvict` in the app, so this is a scope statement, not a regression.

**Fix.** One sentence in the "Transaction ordering" paragraph: *"`clear()` is JVM-local under the default Caffeine profile, so in a multi-replica deployment the residual is the 2–5 min TTL on every replica that did not serve the write, not one round trip. The redis profile exists for exactly this and is enabled nowhere."*

---

## LOW

### L-1 · `Collections.sort` is stable, so a second `HIGHEST_PRECEDENCE` sibling would make precedence depend on bean-creation order — and AC-20 cannot see it

Confirmed against `AnnotatedEventHandlerInvoker` 4.5.7:

```java
			events.add(handlerMethod);
			Collections.sort(events);
			handlerMethods.put(eventType, events);
```
and
```java
		public int compareTo(EventHandlerMethod o) {
			return AnnotationAwareOrderComparator.INSTANCE.compare(this.method, o.method);
		}
```

The javadoc's mechanism claim is **correct as stated** — bare `for` loop, no `try`/`catch`, sorted by `AnnotationAwareOrderComparator` on the *method*; `PutawayConfigRepositoryEventHandler` declares no `@Order` at all, so it lands at `LOWEST_PRECEDENCE` and our methods deterministically win today. M2 proved the mitigation is really load-bearing.

The unstated case: `compareTo` returns 0 for two methods at the same order value, and `Collections.sort` is TimSort, i.e. **stable** — so ties fall back to insertion order, which is `postProcessAfterInitialization` order, which is bean-creation order. A future sibling that also declares `HIGHEST_PRECEDENCE` therefore gets a precedence decided by container wiring, silently and environment-dependently. AC-20 registers a `ThrowingSibling` with **no** `@Order`, so it cannot detect this.

**Fix.** One sentence in the `@Order` paragraph, and optionally a second `@Order(HIGHEST_PRECEDENCE)`-carrying `ThrowingSibling` variant in AC-20 registered *before* the handler, asserted as a known limitation rather than as a guarantee.

### L-2 · The `@Order` analysis covers ordering *within* the invoker, not *between* `ApplicationListener`s

`ValidatingRepositoryEventListener` is a second `ApplicationListener<RepositoryEvent>`, and `RestConfiguration` registers validators for the **after** phases:

```java
        validatingListener.addValidator("afterCreate", validator());
        ...
        validatingListener.addValidator("afterSave", validator());
```

Neither it nor `AnnotatedEventHandlerInvoker` implements `Ordered`, so their relative order is the multicaster's default. If the validator ran first and threw on `afterSave`, the invoker would never be reached and `@Order` on our methods would buy nothing.

Practically near-impossible — `beforeSave` validates the same object with the same validator and would have thrown first — which is why this is Low, not Medium. But the javadoc presents the ordering mitigation without naming its boundary.

**Fix.** Add "*within `AnnotatedEventHandlerInvoker`*" to the claim, and one clause noting the cross-listener case is out of `@Order`'s reach and is judged unreachable because `beforeSave` validates first.

### L-3 · Broken javadoc cross-reference — `SdrCacheEvictionRegistrationContextTest` does not exist

`SdrCacheEvictionUnitTest.java`:

> `{@code SdrCacheEvictionRegistrationContextTest} is the other half and the two are only meaningful together.`

`find src/test -name 'SdrCacheEvictionRegistrationContextTest.java'` → nothing. The class is `SdrCacheEvictionRegistrationUnitTest`. (I checked the four other class names these files cite — `CacheEvictionOnWriteUnitTest`, `SdrWriteWithdrawalContextTest`, `SdrWriteExposureUnitTest`, `AccessChainSdrWriteExposureUnitTest` — all four exist.)

**Fix.** Rename in the javadoc.

### L-4 · The `MANDATORY` citation is wrong by one hop

`SdrCacheEvictionEventHandler.java`:

> `{@code PutawayConfigRepositoryEventHandler.onAfterSave(Sysprop)} calls {@code auditAndEvictWarehouse}, a DB write on a {@code MANDATORY} propagation path that can throw.`

`PutawayConfigService.auditAndEvictWarehouse` is annotated:

```java
    @Transactional(value = "tenantTransactionManager")
```

— plain `REQUIRED`. `grep -rn MANDATORY src/main/java/net/aim_ai/wms/` shows the `Propagation.MANDATORY` sits one level down, on `PutawayConfigAuditService` (`:40`). Because `auditAndEvictWarehouse` opens its own transaction, the `MANDATORY` child is *satisfied*, not violated — so a reader who takes the sentence literally will expect an `IllegalTransactionStateException` that cannot occur.

The conclusion survives (it is still a DB write that can throw, which is all the `@Order` argument needs), so this is a citation defect, not a reasoning defect.

**Fix.** "…calls `auditAndEvictWarehouse`, a transactional DB write (its audit hop is `Propagation.MANDATORY`) that can throw."

### L-5 · "The caches are in any case already smaller than one tenant's working set" is false for `sysprops` — the one cache the defect was measured on

`SdrCacheEvictionEventHandler.java`:

> `The caches are in any case already smaller than one tenant's working set (100 entries against 156 client rows; 2000 against 2749 locations on {@code dev_wh01_om1})`

Measured just now on `dev_wh01_om1`:

| cache | `CacheConfig` maxSize | rows | smaller? |
|---|---|---|---|
| clients | 100 | 156 | ✅ |
| locations | 2000 | 2749 | ✅ |
| itemdata | 3000 | 8805 | ✅ |
| **sysprops** | **200** | **159** | **❌ cache is larger** |

Two of the four cited numbers are exactly right; the generalisation over "the caches" is not, and the counter-example is `sysprops` — the cache `PATCH /v3/sysprop/129` hit. So the "capacity eviction was already dropping these anyway" softener does not apply to the ticket's own reproduction case.

**Fix.** Scope the sentence: "three of the four caches are already smaller than one tenant's working set (…); `sysprops` at 200 is larger than the 159 rows on `dev_wh01_om1`, so for that one the `clear()` really does discard live entries — at admin-console frequency."

### L-6 · The `cacheManager == null` branch is unreachable and untested

```java
        if (cacheManager == null) {
            LOG.warn("no CacheManager wired — SDR eviction of cache={} skipped", cacheName);
            return;
        }
```

The javadoc justifies it as *"reachable only from a test that constructs this handler without one"* — and no such test exists. `CacheManager` is a required constructor argument, so the container fails to start rather than injecting null. By its own stated reachability the branch is dead.

Note this does not contradict the PIT 15/15 result: negating the conditional makes every eviction test fail, so the mutant is killed even though the branch never executes.

**Fix.** Either delete the branch, or add the one-line test the javadoc implies (`new SdrCacheEvictionEventHandler(null).onAfterSave(new Sysprop())` must not throw) so the justification and the coverage agree. I'd keep it and add the test — it is two lines and the file's whole ethic is that a guard without a test is a claim without an instrument.

### L-7 · Two nits

- The four constants `CLIENTS` / `LOCATIONS` / `SYSPROPS` / `ITEMDATA` are package-private but referenced nowhere outside the class (`grep` across `src/main` and `src/test` finds no external use — the tests re-declare the literals). Make them `private`.
- `AC-12 handlers_shouldEvictItemdata` bundles save, create and delete into one test; a save regression masks the other two, and the failure output names only the first. The other three entities each get three separate tests — match that shape.

---

## Checked and found CORRECT (stated so the author knows the coverage, not as padding)

| Claim | Instrument | Verdict |
|---|---|---|
| Four cache names match `CacheConfig` exactly | read `CacheConfig.caffeineCacheManager` + `redisCacheManager`; **M3** mutation | ✅ and a typo is caught |
| No SDR association resources exist for the four types | `grep -rl '@ManyToMany\|@OneToMany\|@ManyToOne\|@OneToOne' src/main/java/net/aim_ai/wms/model/` → **only** `OutboxMessage`, `UserRole`, `UserGroup`, `User` | ✅ independently confirms `RestConfiguration`'s own measurement; `@HandleAfterLinkSave`/`LinkDelete` are correctly absent |
| PATCH, PUT, POST and DELETE all publish `After*` events | `RepositoryEntityController` `saveAndReturn` / `createAndReturn` / `deleteItemResource` | ✅ PATCH and PUT-on-existing both route through `saveAndReturn` → `AfterSaveEvent`; PUT-on-missing → `AfterCreateEvent` |
| A base-typed method would match every SDR domain type | `ClassUtils.isAssignable(handlerMethod.targetType, src.getClass())`, invoker `:69` | ✅ |
| The invoker APPENDS across beans | `events.add(handlerMethod)`, invoker `:160`; AC-17 drives the real BPP | ✅ |
| Bare loop, no `try`/`catch`, sorted by `AnnotationAwareOrderComparator` on the method | invoker `:65-85`, `:161`, `:191` | ✅ (see L-1 for the tie caveat) |
| Redis `clear()` is `KEYS` + `DEL`, not `SCAN` | `RedisCacheWriter.nonLockingRedisCacheWriter` → `BatchStrategies.keys()`; `BatchStrategies.Keys.cleanCache` does `commands.keys(pattern)` then `commands.del(...)` | ✅ exactly as claimed |
| `Itemdata` is in `SDR_WRITE_WITHDRAWN` | `RestConfiguration` array | ✅ |
| `spring.jpa.open-in-view=false`; no `@Transactional` on `RepositoryEntityController` | `application.properties:67`, `application-integration.properties:31`; grep of the SDR sources | ✅ commit-before-event ordering claim holds |
| prd 1 tenant row · dev 1 **active** · UAT 4 active keys | `landlord-prd` / `landlord-dev` / `landlord-uat` `tenant_db_configuration` | ✅ dev has 4 rows, exactly one `active = True` (`wineco`/`wsl`); UAT has 4, all active |
| 156 clients / 2749 locations on `dev_wh01_om1` | `wms2-wineco-dev` | ✅ exact |
| Negative controls AC-22..25 genuinely prove the harness caches | **M4** | ✅ 12 eviction tests stay green, exactly the 4 controls go red |
| The `@Configuration` → plain `@Bean`-holder change did not disable `@EnableCaching` | **M4** (the controls are red only when I remove `@EnableCaching`, green otherwise) | ✅ `@EnableCaching` on a lite config superclass is honoured |
| Fresh-instance-per-call defeats stub aliasing | **M5** | ✅ aliasing + no-op handler makes AC-1 pass falsely — the hazard is real and the mitigation is the thing preventing it |
| No JUnit parallel execution to make the static `AtomicReference` harness state flaky | no `junit-platform.properties`; no `parallel`/`threadCount` in `pom.xml` | ✅ |
| Thread safety, log levels, exception handling | `clearQuietly` is stateless; `warn` for both guard paths and for the swallowed `RuntimeException` is right (a write must not 500 on a cache fault) | ✅ nothing to report |

**No findings at any severity** on: naming, dead code beyond L-6, generics/typing, resource handling, or the choice of a second bean over broadening `PutawayConfigRepositoryEventHandler` (AC-17 and AC-18 justify it against the real invoker, and I confirmed the sibling has no `Location` handlers and no `@Order`).
