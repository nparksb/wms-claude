---
name: wms2-src-wide-scans-also-pick-up-test-classes
description: "Anything scanning `net.aim_ai.wms` — Spring component scan and the reflection-based arch pins alike — also sees src/test classes, so a test-only @Configuration or cache annotation breaks production contexts and production-surface pins; hit twice in one ticket"
metadata: 
  node_type: memory
  type: project
  originSessionId: 6cb9776e-0d51-4b37-8a7e-cab8197878f9
  modified: 2026-09-01T18:05:44.405Z
---

In `wms2-api`, `src/main` and `src/test` share the package root `net.aim_ai.wms`, and **nothing that
scans that root distinguishes them**. A construct written purely as test scaffolding is therefore
visible to production machinery. Measured **twice in one ticket** (SBDEV-3176, 2026-09-01), in two
different subsystems, which is what makes it a class rather than an incident.

**1 — Spring component scan.** Nested `@Configuration` harness classes inside a unit test were
instantiated inside **unrelated `@SpringBootTest` context-load tests**. Their `CacheManager` bean
collided with `CacheConfig.caffeineCacheManager`, and **13 context tests** died with
`No qualifying bean of type 'CacheManager' ... found 2: cacheManager, caffeineCacheManager`.

⚠ The sibling `CacheEvictionOnWriteUnitTest` has the identical exposure and survives **only by
accident**: its `@Bean` method parameter happens to be *named* `cacheManager`, matching the bean name,
so Spring's by-name tiebreak resolves the otherwise-ambiguous injection. Mine was named `cm`. So the
existing green suite is **not** evidence that this pattern is safe.

*Fix:* drop `@Configuration` from nested test configs. `ctx.register(X.class)` still processes their
`@Bean` methods ("lite" mode) and `@EnableCaching` on the lite class is still honoured — but the
classpath scan skips them. Verified by experiment, and guard it: dropping `@Configuration` could
silently disable `@EnableCaching`, which would make every cache test pass vacuously, so add negative
controls asserting the harness really does cache.

**2 — reflection-based arch pins.** `TenantCacheKeyUnitTest` reflects over every class under
`net.aim_ai.wms` and pins the **count** of keyed cache annotations plus "none omits its key". A test
stub interface carrying `@Cacheable("clients")` with no key attribute broke that pin from a test file:
`Expected size: 21 but was: 22`.

⚠ The trap inside the trap: the obvious "fix" is to bump the count constant — which **silently weakens
a guard that exists to inventory production**. The right fix was to remove the annotation from the
stub (warm the cache through the `CacheManager` directly instead), leaving the pin at 21.

Note `cacheKeysOn` deliberately exempts `@CacheEvict(allEntries = true)` — an all-entries evict has no
key to check — so adding `allEntries` evictions to `src/main` does **not** move that count.

## How to apply

- Before adding **any** annotation to test scaffolding that production machinery scans —
  `@Configuration`, `@Component`, `@Cacheable`, `@CachePut`, `@CacheEvict`, `@Entity` — ask what in
  `src/main` reflects over `net.aim_ai.wms`.
- When a src-wide count pin moves after your change, **find out which annotation moved it before
  touching the constant.** If the answer is one of yours in `src/test`, the fix is in your test.
- A green suite around an existing test-only construct does not prove the pattern is safe; it may be
  surviving on a name coincidence, as the cache-harness sibling does.

Related: [[green-tests-that-prove-nothing]],
[[verify-spring-bean-changes-clean-compile-and-context-load]] (the full-context-load run is what caught
case 1 — no unit test could), [[mutation-harness-traps]], [[sbdev-3176-sdr-cache-eviction]].
