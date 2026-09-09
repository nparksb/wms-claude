# SBDEV-3176 — implementation evidence

Tier **T2**. Worktree `.claude/worktrees/wms2-api/SBDEV-3176`, branch
`bugfix/SBDEV-3176-sdr-cache-eviction`, off `origin/develop@92ca2e38`.

## Triage probe

| Question | Answer |
|---|---|
| already fixed? | **no** — no commit matching `3176`; exactly one `@RepositoryEventHandler` on `origin/develop` |
| reproduces? | **yes** — sysprop staleness measured live 2026-08-31; no commit since touches the mechanism |
| real cause? | **as reported** — `config/PutawayConfigRepositoryEventHandler`, every After-phase evict sits behind the putaway-delta early return |
| one line? | **no** — one new class, two test classes |

## Ticket premises re-verified against `origin/develop`

All confirmed. `Itemdata` **is** in `RestConfiguration.SDR_WRITE_WITHDRAWN`, so the ticket's 405
control is genuine; `client`, `location` and `sysprop` are among the eleven resources the same file
names as deliberately kept writable. `@HandleAfterDelete` exists for `Sysprop` only. No `Location`
handler exists anywhere in `config/`.

## Corrections to the plan of record

1. **`CacheConfig` declares TWO cache managers**, not one — `caffeineCacheManager` under
   `@Profile("!redis")` and `redisCacheManager` under `@Profile("redis")`. The null-cache rationale in
   the ticket is right for the default profile; on the Redis profile `clear()` is additionally a
   `SCAN`+`DEL` propagating to every replica.
2. **The baseline in the ticket is stale.** It records `5803 / 0 / 67` at `3a3acf3e`. Measured fresh on
   this worktree at `92ca2e38`: **5982 / 0 failures / 0 errors / 67 skipped, `BUILD SUCCESS`.** Counts
   move with every merge — do not carry a number forward from a document.
3. **`ItemdataService.getById` throws `EntityNotFoundException`**, it does not return null. The
   post-delete assertion asserts the throw, which is the stronger signal: a stale cache would have
   returned the entity without consulting the repository at all.

## A measurement trap in the ticket's own acceptance item

The ticket asks for the live dev probe to be re-run for `client` and `location`. Measured on
`dev_wh01_om1`: **156 client rows against a 100-entry `clients` cache, and 2749 location rows against
a 2000-entry `locations` cache.** Both production caches are smaller than the populations they serve
on a *single* tenant, and keys are tenant-prefixed so one cache holds every tenant's entries.

A live probe can therefore show a fresh read because **capacity eviction** dropped the entry, not
because the fix worked — a false green in the direction that confirms what we want to believe. The
unit harness uses an unbounded `ConcurrentMapCacheManager` precisely so that cannot happen.

## Floor

| Item | Evidence |
|---|---|
| DB query confirming the symptom | `los_sysprop id=129` → `MOBILE_UI_URL`, value byte-identical to the recorded original, `version = 2` (moved 0→1→2). Confirms the 2026-08-31 probe was real **and** cleanly reverted |
| failing test first, right reason | **12 failures, 0 errors**, every one an `AssertionError` naming the stale value (`expected: 20L but was: 10L`; `expected: "after" but was: "before"`) — not a compile error, not an NPE in setup |
| mutation-check every assertion | **PIT 15/15 killed, 0 survived, 0 no-coverage**, scoped to the handler. Each of the twelve methods has its own `VoidMethodCallMutator` killed by its own test |
| — the two mutants PIT cannot express | PIT has no mutator that makes `clear()` throw, so the two `Guards` tests killed nothing. Hand-mutated instead: removing the `catch` → AC-14 red naming `IllegalStateException: redis down`; removing the null-cache guard → AC-13 red naming `Cannot invoke "Cache.clear()" because "cache" is null`. Both attributable |
| — the registration suite | Removing `@RepositoryEventHandler` turns **all 5 red**, each naming the registration failure. Not vacuous |
| independent review | 2 lanes (T2), reports on disk — see this directory |
| full suite vs baseline | baseline **5982 / 0 / 67**; post-fix run recorded below |

⚠ **A restore trap was hit and caught.** `git checkout --` silently fails on the new handler because
it is **untracked** — it printed `did not match any file(s) known to git` and left the mutant in
place. Every subsequent restore was done by `cp` from a saved copy and verified with `md5sum` +
`diff -q`. This is the mtime/restore family of harness lies the repo has already recorded; the fix is
to verify the restore, never to assume it.

## What the tests deliberately cannot see

`SdrCacheEvictionUnitTest` calls the handler methods directly, so it is structurally blind to SDR
never invoking them — the only failure mode that matters in production.
`SdrCacheEvictionRegistrationUnitTest` closes that by driving the **real**
`AnnotatedEventHandlerInvoker` from spring-data-rest-core 4.5.7 and publishing real
`AfterCreate`/`AfterSave`/`AfterDelete` events. Neither proves the running Spring Boot application
creates the bean — that needs the full application context, which does not start in the unit lane.
AC-19 narrows that residue to component scanning of `net.aim_ai.wms.config`, the package that already
hosts `PutawayConfigRepositoryEventHandler`.

Also unclosed, and stated in the ticket: no `TransactionAwareCacheManagerProxy` is configured
anywhere, so eviction from an SDR event handler can land before the surrounding transaction commits
and a concurrent read can re-warm from pre-commit state. The stale window shrinks from the TTL to
milliseconds — **not to zero.** Same limitation as every other eviction in this codebase.

---

## Findings the ticket's design did not anticipate

### 1. `@Order` is required — the ticket would have shipped a silent failure

`AnnotatedEventHandlerInvoker.onApplicationEvent` (spring-data-rest-core 4.5.7, read from the sources
jar) dispatches through a bare loop with **no try/catch**, over a list sorted by
`AnnotationAwareOrderComparator` applied to the **method**. A sibling handler method that throws
therefore aborts dispatch and every later method silently never runs.

That is reachable: `PutawayConfigRepositoryEventHandler.onAfterSave(Sysprop)` calls
`auditAndEvictWarehouse`, a DB write on a `MANDATORY` propagation path. Without ordering, an audit
failure takes cache coherence down with it and leaves no trace.

Closed with `@Order(Ordered.HIGHEST_PRECEDENCE)` on all twelve methods, pinned by **AC-20** (a
throwing sibling must not suppress eviction) and **AC-21**. Stripping the twelve annotations turns
both red, attributably.

### 2. Twelve methods over four concrete types, never one over `AbstractBaseEntity`

Dispatch filters with `ClassUtils.isAssignable`, and all four entities extend `AbstractBaseEntity`, so
one base-typed method would clear a cache on **every** SDR domain type in the application.

### 3. The ticket's transaction-race caveat does not apply here

`spring.jpa.open-in-view=false`, no `@Transactional` on `RepositoryEntityController` or any filter,
and `SimpleJpaRepository.save` carries its own — the commit completes inside `invokeSave(...)` before
the event is published. The residue is a one-round-trip read-through re-warm, which no
evict-after-write scheme closes. `TransactionAwareCacheManagerProxy` deliberately not introduced: its
`clear()` is a literal no-op with no synchronization active, and it would re-time every existing
in-transaction `@CacheEvict`. **Inverts if OSIV is ever enabled.**

### 4. Redis `clear()` is `KEYS` + `DEL`, not `SCAN` + `DEL`

`RedisCacheManager.builder` yields a non-locking writer using `BatchStrategies.keys()` — blocking, not
cursored. Latent: the `redis` profile is activated in no environment. Corrects an earlier note of mine
on the ticket.

## A regression I introduced, caught by the full suite and not by any unit test

The first full run came back **6001 / 0 failures / 32 errors / BUILD FAILURE** against a
5982 / 0 / 0 / 67 baseline. Thirteen Spring **context-load** tests failed with
`No qualifying bean of type 'CacheManager' ... found 2: cacheManager, caffeineCacheManager`.

It was tempting to write this off as the known "concurrent Maven in one worktree" false red, since a
second Maven had indeed been running. **It was not.** The isolating experiment — production class
present, my two test files moved out, one failing context test re-run — came back green, which puts
the cause in the tests, not the bean.

Cause: my nested `@Configuration` harnesses were being **component-scanned into unrelated production
contexts**, where their `CacheManager` bean collided with `CacheConfig.caffeineCacheManager`. The
sibling `CacheEvictionOnWriteUnitTest` has the same latent exposure and survives only because its
`@Bean` parameter is *named* `cacheManager`, matching the bean name so Spring's by-name tiebreak
resolves the ambiguity; mine was named `cm`. Fixed by dropping `@Configuration` so the harnesses are
plain `@Bean` holders that `ctx.register()` still processes but the classpath scan ignores. The
sibling is untouched — latent, working, and outside this ticket.

**This is the "gate Spring bean changes on a full context load" lesson, and no unit test could have
caught it.**

### That fix created a vacuity risk, so it needed its own control

Dropping `@Configuration` could have silently disabled `@EnableCaching` in the harness — and if the
harness stops caching, every reader returns fresh data and **all twelve eviction assertions pass for
the wrong reason.** AC-22 … AC-25 are the negative controls: same warm, same DB change, **no handler
invocation**, and the reader must return the STALE value. AC-24 is the dev-measured sysprop symptom
reproduced in JUnit.

## Live probe for client / location — deliberately NOT run

Nam's call, 2026-09-01, on the evidence below. Recorded so the AC is closed with a reason rather than
left ambiguous.

The two entities the ticket wanted probed are exactly the two whose caches are **over-subscribed**
(clients 156 rows vs 100 entries; locations 2749 vs 2000; itemdata 8805 vs 3000), while the one that
*was* successfully probed is not (sysprops 159 vs 200). A naive live probe on client/location can
therefore show a fresh read because capacity eviction dropped the entry — a false green in the
direction that confirms the hypothesis. Caffeine is Window-TinyLFU, so an entry read once can be
dropped after a handful of distinct reads, not ~100.

The exposure half was already measured on 2026-08-31 (`PATCH /v3/client/{id}` → 200). What remained
unmeasured was the cache consequence, and that is now covered by AC-1…AC-8 plus the negative controls
— on an unbounded, non-expiring cache where neither confound exists.

If a live probe is ever wanted, the sound instrument is
`GET /actuator/metrics/cache.evictions?tag=cache:clients` either side, requiring delta 0: Caffeine's
`evictionCount()` excludes manual invalidations while `SIZE` and `EXPIRED` both count, and
`CaffeineCache.clear()` is `invalidateAll()` — so that counter measures the confound and never the
fix. It is JVM-local, so dev must be confirmed single-replica first.

---

## The "container half" is NOT unprovable after all — live evidence exists

Found by review lane B, and independently re-verified here. I had written that no test can prove the
running Spring Boot application actually creates the bean and registers the BPP. That is true of the
*test suite*, but the dev database already answers it:

```sql
SELECT channel, count(*) FROM putaway_config_audit GROUP BY channel;
--  migration  8803
--  typed         6
--  hal           1     <- 2026-08-26 17:10:52Z
```

`CHANNEL_HAL` is written at exactly **one** site (`PutawayConfigService:567`), and the only callers of
the `auditAndEvict*` family it sits behind are `PutawayConfigRepositoryEventHandler`'s `@HandleAfter*`
methods — verified by grep over `src/main`. So that single row is a live, deployed-container proof
that Spring really does post-process a `@Component @RepositoryEventHandler` sitting in
`net.aim_ai.wms.config` and dispatch an SDR event to it.

`SdrCacheEvictionEventHandler` carries the same two annotations in the same package, so the registration
mechanism is demonstrated in production rather than only in a harness. **What this does not prove** is
that *this specific bean* is created — only that the mechanism it relies on works in the deployed
container. The remaining gap is component scanning of one more class in an already-scanned package.

---

## Review round — 2 lanes, 15 findings, all addressed

Lane A (`code-reviewer`, adversarial): **1 High · 3 Medium · 7 Low**, with a five-mutation log.
Lane B (`verifier`, conformance + claim fact-check): **0 High · 2 Medium · 4 Low**, conformance PASS.
Both wrote reports to this directory. Lane B re-ran the suite and PIT independently and reproduced
both numbers exactly; it found **no false claim**, which is unusual here and worth recording.

### H-1 — the fix had a real coverage gap, and it is the same pattern as the bug

Two `@Modifying` writes on `ClientRepository` — `toggleEnableReceivingById` and
`updatePrinterToNullByPrinterId` — are SDR-**exported**, so they also answer at
`GET /v3/client/search/{path}`. That route is served by `RepositorySearchController`, and searching all
of spring-data-rest-webmvc 4.5.7 for `publishEvent` finds it in exactly two classes —
`RepositoryEntityController` and `RepositoryPropertyReferenceController` — and **not** in the search
controller. So those writes publish no event and the twelve handler methods are structurally unable to
see them, however many are added.

This is *"a guard fences the mechanism you aimed at"* — the same lesson the ticket cites about
`PutawayConfigRepositoryEventHandler`, recurring one level up. I aimed at SDR's *entity* controller and
the ticket's framing ("SDR writes") read as complete.

**Fixed on the repository methods, not on the callers** — the invariant, not the instances. That single
placement also closes lane A's **M-2**: `updatePrinterToNullByPrinterId`'s one in-process caller is
`PrinterController.deletePrinter`, which carries no eviction, so deleting a printer left its id in every
cached `Client` for up to the TTL. `toggleEnableReceivingById` has no in-process caller at all — the SDR
route is its only one.

⚠ That fix rests on `@CacheEvict` being honoured on an **interface** method. Had that been false the
annotations would be a silent permanent no-op, so it is tested behaviourally (**AC-28**, with its own
negative control) rather than assumed. **AC-29** pins the two real methods. Stated plainly: what remains
unproven is whether Spring Data's proxy is advised in the running container — only the integration lane
settles that.

### Corrections to claims I had made

| # | My claim | Reality |
|---|---|---|
| M-1 | `TransactionAwareCacheDecorator.clear()` is "a literal no-op" with no synchronization active | **False.** It falls through to `targetCache.clear()` — a plain pass-through. The decision survives on its *second* reason (re-timing every existing in-transaction `@CacheEvict`); the first was wrong |
| M-3 | residual is "one round trip" | Understated, and in the direction that flatters the fix. `clear()` is JVM-local under the Caffeine profile, so on a multi-replica deployment the residual is the **full 2–5 min TTL** on every replica that did not serve the write |
| L-4 | `auditAndEvictWarehouse` is "a `MANDATORY` propagation path" | Off by one hop — that method is plain `@Transactional`; the `MANDATORY` is on `PutawayConfigAuditService` below it, and is therefore satisfied, not violated. Conclusion unaffected |
| L-5 | "the caches are already smaller than one tenant's working set" | A completeness word that broke, and on the ticket's own reproduction case: true for clients/locations/itemdata, **false for `sysprops`** (200 entries vs 159 rows) |
| L-1/L-2 | `@Order` fixes the ordering hazard | True but unbounded as written. `Collections.sort` is stable, so two siblings both at `HIGHEST_PRECEDENCE` would be ordered by bean-creation order; and `@Order` orders only *within* `AnnotatedEventHandlerInvoker`, not between `ApplicationListener`s |
| L-3 | javadoc cited `SdrCacheEvictionRegistrationContextTest` | No such class — it is `...UnitTest` |

Every one is now corrected in the javadoc, with its derivation and blind spot stated inline.

### Also done

- **L-6 / lane-B L1** — the `cacheManager == null` branch was dead and its javadoc named a test that did
  not exist. AC-17 now passes `null` directly; removing the guard makes it red with an NPE naming
  `this.cacheManager`. The claim and the instrument now agree.
- **lane-B M2** — armed the container tripwire: `PutawayResolverContextLoadTest` now `@Autowired`s the
  handler. Dormant until SBDEV-2217 restores that lane, then automatic.
- **Top residual risk (lane B)** — the post-commit argument depended on `spring.jpa.open-in-view=false`
  as **prose**; enabling OSIV would silently invalidate the design with nothing going red. Now
  **AC-27**. ⚠ Writing it exposed a trap worth keeping: `src/test/resources/application.properties`
  **shadows** the main file on the test classpath and does not carry the key, so a
  `getResourceAsStream` version graded the wrong file. It reads `src/main/resources/...` by path.
- **L-7** — the four cache-name constants are now `private`; `AC-12` was one test bundling save+create+
  delete (a save regression masked the other two) and is now three.

### Deliberately not done

- **lane-B M1** — a post-deploy sysprop re-probe. `sysprops` is the one cache capacity does *not*
  confound (159 rows < 200 entries), so unlike client/location it is a sound live instrument. Recorded
  on the ticket as a **post-deploy verification step**, not done pre-merge.
- **lane-A M-2's alternative** (annotating `PrinterController`) — superseded: the repository-level evict
  covers it.

## Process notes worth keeping

- A `-Dtest=` pattern with several comma-separated wildcards made surefire fail with
  `TestEngine with ID 'junit-jupiter' failed to discover tests` and **0 tests run**. Each class passed
  when named alone. A tooling artifact that reads exactly like a broken test class.
- PIT died once with `Coverage generator Minion exited abnormally (UNKNOWN_ERROR)` against a stale
  `target/`; `mvn -o clean test-compile` first fixed it and PIT then reproduced 15/15.

---

## Two more traps, both hit while FIXING the review findings

### 1. A src-wide reflection pin scans TEST classes too — the second time this session

`TenantCacheKeyUnitTest` reflects over every class under `net.aim_ai.wms` and pins (a) the total count
of keyed cache annotations and (b) that none omits its key. My H-1 test used a stub interface carrying
`@Cacheable("clients")` with no key attribute — and that **broke a production-surface pin from a test
file**: `Expected size: 21 but was: 22`, with the offending entry being the empty key.

Note `cacheKeysOn` correctly exempts `@CacheEvict(allEntries = true)`, so the two real repository
annotations were never the problem — a fact that took a moment to establish and would have been easy to
"fix" in the wrong place by bumping the count pin, which would have silently weakened a guard that
exists to inventory production.

Fixed by removing `@Cacheable` from the stub entirely: AC-28 now warms through the `CacheManager`
directly, which proves the same property and adds nothing to an inventory meant for `src/main`.

**This is the same shape as the earlier `@Configuration` component-scan failure.** Twice in one ticket,
a test-only construct was picked up by machinery that scans `net.aim_ai.wms` and does not distinguish
`src/main` from `src/test`. Worth remembering as a class rather than as two incidents.

### 2. `git checkout --` is the wrong restore for BOTH kinds of file, in opposite directions

- On an **untracked** file it silently fails (`did not match any file(s) known to git`) and leaves the
  mutant in place — caught earlier by an `md5sum` check.
- On a **tracked, uncommitted-modified** file it succeeds and **discards the real work**. That is what
  happened to the H-1 fix on `ClientRepository.java`: reverting mutant H took the fix with it, and the
  file quietly dropped out of `git status`.

Both were caught, the second by grepping for the annotation count immediately after the restore rather
than trusting it. **The rule: restore from an explicit saved copy and verify with `diff`/`grep`, never
from git, whenever the file has uncommitted work in it.**

Worth noting AC-29 would also have caught the second one at the next full run — the shape pin lane B's
sibling asked for turned out to guard the fix against my own tooling.
