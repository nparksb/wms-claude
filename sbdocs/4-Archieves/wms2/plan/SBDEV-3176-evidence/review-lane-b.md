# SBDEV-3176 — review lane B: conformance + adversarial claim verification

- **Date:** 2026-09-01
- **Commit under review:** `4d3000fd` — *fix(cache): SBDEV-3176 — evict entity caches on Spring Data REST writes*
- **Parent / baseline:** `92ca2e38`
- **Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/3176-review-b`
- **Scope:** conformance to the ticket + adversarial fact-check of the author's claims. Not general
  code review (lane A).
- **Toolchain note:** `mvn` is not on the default PATH in this session. Everything below was run with
  `PATH=$HOME/.sdkman/candidates/maven/current/bin:$HOME/.sdkman/candidates/java/current/bin:$PATH`.
  A run without that produces `mvn: command not found` / exit 127, which surefire-shaped tooling
  records as an ordinary failure — the known false-red.

---

## Verdict

**Conformance: PASS with two Mediums.** Every item in the ticket's *Recommended fix*, *Design
specifics* and *The testing point that actually matters* is met, several beyond what was asked. One
acceptance item was deliberately not run, and the stated reason covers **less than the whole gap** —
that is M1. The commit is a pure addition (3 files, 1096 insertions, **0 deletions**), so nothing
pre-existing was touched.

**Claim verification: every checkable claim SURVIVED.** This is unusual for this repo. I re-ran the
suite and PIT myself and re-derived the DB and landlord numbers from the live databases; all match to
the digit. The load-bearing completeness claim (*zero JPA association annotations*) survives, and I
found a **second, independent instrument** confirming it that the author did not cite. I found no
false claim. Two claims are true but under-derived (F1, F2 below).

**Net new evidence from this lane:** I found live proof of the container half that the author
explicitly said was unobtainable — see **§C.0**. It materially de-risks the residual gap.

| Severity | Count |
|---|---|
| High | 0 |
| Medium | 2 |
| Low | 4 |

---

## A. Conformance, item by item

### A.1 "Recommended fix"

| Ticket item | Verdict | Evidence |
|---|---|---|
| Do **not** broaden `PutawayConfigRepositoryEventHandler` | **MET** | `git show 4d3000fd --numstat` → three files, all new, `0` deletions. That file is not in the diff. |
| A second handler bean is safe — appended, not replaced | **MET, upgraded** | The ticket rested this on reading the jar. AC-17 *executes* it: it registers both real beans through the real `AnnotatedEventHandlerInvoker`, reflects into the private `handlerMethods` map and asserts `AfterSaveEvent` dispatches to **two distinct handler bean classes**. Argument → evidence. |
| Zero JPA associations ⇒ no `@HandleAfterLinkSave` / `@HandleAfterLinkDelete` | **MET** | See F3 — verified twice, independently. |
| "3 entities × 3 events = 9 one-line methods" | **MET** (the ticket's own arithmetic wobbles) | 12 methods shipped. The ticket says 9 in one bullet and "include `Itemdata`'s three methods" in the next; 9 + 3 = 12. Not a deviation. |

### A.2 "Design specifics"

| Ticket item | Verdict | Evidence |
|---|---|---|
| `clear()`, not key-scoped | **MET, pinned** | Not merely implemented — pinned by two tests a key-scoped variant *cannot* pass: **AC-4** renames `clNr` C1→C2 and asserts the OLD key stops resolving; **AC-8** does the same for `Location.name`. |
| Include `Itemdata`'s three methods as dead-today insurance, **with a comment saying so** | **MET** | Class javadoc §"On the `Itemdata` methods: dead today, deliberately kept"; the nested test class is literally named `ItemdataInsurance`; AC-12 exercises all three. |
| Reuse PR #250's guarded-helper shape: null-check with a WARN, never let eviction failure escape | **MET / PARTIAL** | The null-**cache** WARN (AC-13) and the `catch RuntimeException` (AC-14) are both present and tested. The null-**manager** branch is present but dead and untested — **L1**. |

### A.3 "The testing point that actually matters"

The ticket asked for two parts.

| Ticket item | Verdict | Evidence |
|---|---|---|
| (1) behavioural unit tests over a real Spring cache proxy | **MET, exceeded** | 18 tests on a real `@EnableCaching` proxy over an unbounded, non-expiring `ConcurrentMapCacheManager`. Every stub returns a **fresh** instance per call (`ClientHarness.row()` etc.), which closes the aliasing trap `CacheEvictionOnWriteUnitTest` was caught by twice. **AC-22…25 are negative controls the ticket did not ask for** and they are the right ones: same warm, same DB change, *no handler invocation*, reader must be STALE. Without them a harness that lost its cache proxy would turn all twelve eviction assertions green for the wrong reason. |
| (2) "**one context test** asserting the handler is genuinely registered for the right event types" | **DEVIATED-WITH-REASON** | Delivered as a *unit* test (`SdrCacheEvictionRegistrationUnitTest`), not a Spring context test. The reason is real and independently confirmed: `PutawayResolverContextLoadTest`'s own javadoc records `TODO(SBDEV-2217): ... this class does not run in CI today`. The substitute drives the real production dispatcher and is strictly stronger than the context test the repo actually has, which asserts only `assertThat(putawayConfigRepositoryEventHandler).isNotNull()` — a bean can exist having registered zero handler methods. The free mitigation was still skipped — **M2**. |

**On AC-20, the ordering test — I checked it is not vacuous.** It registers `ThrowingSibling` *first*,
then the eviction handler. `AnnotatedEventHandlerInvoker.inspect` appends and `Collections.sort` is
stable, so with the `@Order` annotations stripped both methods resolve to `LOWEST_PRECEDENCE`,
insertion order survives, the sibling throws first and eviction never runs → red. The author's claim
that stripping the twelve annotations turns AC-20 red is correct, and it is correct *because of the
registration order chosen in the test*. That ordering is load-bearing and undocumented in the test.

### A.4 "Floor / acceptance"

| Item | Verdict | How I checked |
|---|---|---|
| Re-run the probe for `client` and `location` | **NOT DONE — deliberate** (Nam, 2026-09-01) | Judged in **§A.5** and **M1**. |
| One failing test first, failing for the right reason | **MET** (author's log, not re-derived by me) | `3176-red.log`: `Tests run: 14, Failures: 12, Errors: 0` — 12 failures, **zero errors**, so not a compile error or an NPE in setup. 14 (not 18) because the four negative controls were added later, which is consistent with the `@Configuration` regression narrative. I did not re-run the red. |
| Mutation-check every new assertion, and separately prove registration | **MET — re-run by me** | See F5. |
| One independent review, never self-approve | **MET** | This lane + lane A. |
| Full suite vs baseline | **MET — re-run by me** | See F4. |

### A.5 Does the substitute evidence cover what the skipped probe would have?

The skipped acceptance item would have delivered three things. Scoring them honestly:

| What the live probe would have shown | Covered by the substitute? |
|---|---|
| (a) the **cache consequence** for `client` / `location` | **Yes — better than the probe could.** AC-1…8 plus AC-22/23 run on an unbounded, non-expiring cache where neither capacity eviction nor `expireAfterWrite` exists. Nam's rationale here is sound and I verified its premises independently (F6): `clients` 156 rows vs 100 slots, `locations` 2749 vs 2000. A live probe genuinely could have shown a fresh read for the wrong reason. |
| (b) that the real SDR route publishes `AfterSave` for these types in the deployed app | **Partially.** The publish sites in `RepositoryEntityController` were *read* from the jar, not executed. The invoker's contract is executed (AC-15…18). |
| (c) that the **container** creates this bean and hands it to the invoker | **No — by nothing in the commit.** The author states this plainly and does not overclaim. |

**The gap in the rationale is (c) combined with the choice of dataset.** The capacity argument
justifies skipping `client` and `location`. It does **not** justify skipping a post-deploy re-probe on
**`sysprops`** — 159 rows against 200 slots, which the author's *own* analysis certifies as
structurally free of capacity eviction ("the reason the 2026-08-31 live sysprop measurement is
trustworthy"). That probe costs ~5 minutes, is confound-free by the author's own reasoning, is the
exact dataset whose staleness was measured pre-fix, and is the **only** cheap instrument that touches
(b) and (c) at once. The evidence file frames the skip purely as a capacity problem, which reads as
though the whole acceptance item were confounded. It is not: one third of it was clean. → **M1**.

---

## B. Adversarial claim verification

I prioritised completeness claims over quantitative ones per the brief. In this commit that
prioritisation was wrong-footed: **the completeness claims survived too.**

### F1 — Suite arithmetic: **TRUE**, and I re-derived it two ways

> "Suite 6007/0/0/67, baseline 5982/0/0/67 at 92ca2e38 (+25 = the new tests)."

I re-ran `mvn -o clean test` in my worktree:

```
[WARNING] Tests run: 6007, Failures: 0, Errors: 0, Skipped: 67
[INFO] BUILD SUCCESS
```

Exact match. I did **not** re-run the baseline, and I did not need to — it is derivable and airtight.
Surefire's per-class lines for the new classes:

```
Tests run: 7 -- SdrCacheEvictionRegistrationUnitTest
Tests run: 4 -- SdrCacheEvictionUnitTest$NegativeControls
Tests run: 2 -- SdrCacheEvictionUnitTest$Guards
Tests run: 1 -- SdrCacheEvictionUnitTest$ItemdataInsurance
Tests run: 3 -- SdrCacheEvictionUnitTest$Sysprops
Tests run: 4 -- SdrCacheEvictionUnitTest$Locations
Tests run: 4 -- SdrCacheEvictionUnitTest$Clients
```

7 + 4 + 2 + 1 + 3 + 4 + 4 = **25**. The commit has **0 deletions** across 3 files, so no pre-existing
test could have changed the count. 6007 − 25 = **5982**. Confirmed.

**Note the claim is stronger than the author stated it.** "+25 = the new tests" is asserted; the
0-deletion property is what makes it *provable* rather than coincidental. Worth one clause in the
commit message. (Classified below as F1-note, Low → folded into L4.)

### F2 — PIT "15/15 killed, 0 survived": **TRUE**, re-run by me

```
> org.pitest.mutationtest.engine.gregor.mutators.VoidMethodCallMutator
>> Generated 13 Killed 13 (100%)
> org.pitest.mutationtest.engine.gregor.mutators.NegateConditionalsMutator
>> Generated 2 Killed 2 (100%)
>> Generated 15 mutations Killed 15 (100%)
>> Mutations with no coverage 0. Test strength 100%
```

Exact match, including `0 no coverage`. The 15 also **decompose cleanly**, which is the check that
tells you the number is real rather than a coincidence: 12 `VoidMethodCall` on the twelve
`clearQuietly(...)` call sites + 1 on `cache.clear()` = 13; 2 `NegateConditionals` on the two null
checks. No other mutator applies (PIT filters logging calls by default, so the two `LOG.warn` calls
generate nothing). The author's separate note that PIT has no mutator able to make `clear()` throw is
consistent with this breakdown, and their hand-mutation of AC-13/AC-14 is the right compensation.

### F3 — "Client, Location and Sysprop carry ZERO JPA association annotations": **TRUE**

This is the load-bearing completeness claim (it is why no `@HandleAfterLinkSave` was written), so I
checked it two ways.

**Instrument 1 — direct.** Grepping all of `@OneToMany|@ManyToOne|@OneToOne|@ManyToMany|@ElementCollection|@Embedded|@JoinColumn|@JoinTable`
across `Client.java`, `Location.java`, `Sysprop.java`, `Itemdata.java` **and their shared superclass
`AbstractBaseEntity.java`** returns nothing. Checking the superclass matters and the author's
statement does not mention it. Every declared field is a scalar — e.g. `Client`:

```java
private Long sectionId;
private Long printerreceivingId;
private Long defaultputawaylocationId;
```

**Instrument 2 — independent, and the author did not cite it.** `RestConfiguration` already carries a
measured repo-wide enumeration:

> "Measured: SDR generates exactly THREE association resources repo-wide — `User.groups`,
> `UserGroup.roles`, `UserRole.functions`, the only `@ManyToMany @JoinTable` mappings; everything else
> uses manual FK columns, so `isAssociation()` is false and no association resource exists."

None of the four entities is in that set. The claim survives with two instruments, which is the
standard this repo asks for and which the commit met only by luck of an adjacent comment. Citing it
would cost one line.

### F4 — "Itemdata is in SDR_WRITE_WITHDRAWN; client/location/sysprop are among eleven kept writable": **TRUE**

`RestConfiguration:337` → `net.aim_ai.wms.model.Itemdata.class` is in the array. The kept-writable
javadoc lists exactly eleven, and I counted them: `advice`, `boxtype`, `client`, `customerorder`,
`cyclecount`, `location`, `locationType`, `section`, `sysprop`, `userGroup`, `userRole` = **11**.

**I tried to break the derived claim "the Itemdata methods are unreachable today" and could not.**
The obvious attack is that the ticket's 405 control was measured on `PATCH` (an *item* verb) while
`onAfterCreate(Itemdata)` needs `POST` to the *collection* — a different exposure axis, and the
`PutawayConfigRepositoryEventHandler` javadoc elsewhere refers to "EVERY HAL `POST /v3/itemdata`" as a
live route for the SKU creation screen. But the withdrawal loop closes all three axes at once:

```java
for (Class<?> domainType : SDR_WRITE_WITHDRAWN) {
    config.getExposureConfiguration().forDomainType(domainType)
        .withCollectionExposure((metadata, httpMethods) -> httpMethods.disable(WRITE_VERBS))
        .withItemExposure(...)
        .withAssociationExposure(...);
```

with `WRITE_VERBS = {POST, PUT, PATCH, DELETE}`. Collection POST is withdrawn too. "Unreachable
today" holds. (The HAL-POST reference in that other javadoc is historical, pre-SBDEV-3157.)

### F5 — Transaction ordering and `spring.jpa.open-in-view=false`: **TRUE**

`src/main/resources/application.properties:67` → `spring.jpa.open-in-view=false`, one occurrence, no
profile override in the repo. The rest of the chain (no `@Transactional` on `RepositoryEntityController`,
`SimpleJpaRepository.save` carrying its own, publish sites straddling `invokeSave`) is documented in
the architect consult with jar citations; I spot-checked the app-side links and did not re-open the
jars. The conclusion — After events are post-commit here — is consistent with everything I can see,
and the residual one-round-trip re-warm is stated rather than glossed. The `⚠ inverts if OSIV is ever
enabled` tripwire is in the src/main javadoc, which is the right place for it.

### F6 — DB row counts vs cache sizes: **TRUE, to the digit**

`mcp__wms2-wineco-dev__execute_sql` (first call after idle failed with "server closed the connection",
retried, as expected):

```
db=dev_wh01_om1  clients=156  locations=2749  sysprops=159  itemdata=8805
```

Against `CacheConfig`: `sysprops` 200, `clients` 100, `locations` 2000, `itemdata` 3000. So
`clients` 156 > 100 ✔ over, `locations` 2749 > 2000 ✔ over, `itemdata` 8805 > 3000 ✔ over,
`sysprops` 159 < 200 ✔ under. Every over/under call in the ticket comment, the evidence file and the
src/main javadoc is right. Note the entity table names are `client` / `location` / `itemdata` /
`los_sysprop` — only `Sysprop` carries an `@Table`.

### F7 — "prd has one tenant row, dev one active": **TRUE**

```
landlord-prd (wms2_landlord):  tenant_id=1  warehouse=nywh  active=True          → 1 row
landlord-dev (dev_landlord):   1/wsl active=True; 4/nywh, 7/c1wh, 7/nywh active=False → 1 active of 4
```

Matches the src/main javadoc's blast-radius claim exactly. (I did not re-query UAT; the prd/dev half is
what the javadoc's "zero cross-tenant cost" rests on.)

### F8 — Completeness words: every / only / all / no / exactly / none

I swept the commit message and the class javadoc for these and tried to break each. Results:

| Claim | Verdict |
|---|---|
| "no `@CacheEvict` [on `RepositoryEntityController`], so **no** annotation in the application can observe them" | TRUE |
| "`@Order(HIGHEST_PRECEDENCE)` on **all twelve** methods" | TRUE — AC-21 asserts exactly 12 and `allSatisfy` on the value; I counted 12 in the source |
| "**Twelve** methods over **four** CONCRETE types, **never** one over `AbstractBaseEntity`" | TRUE |
| "dispatch filters with `ClassUtils.isAssignable`, so a base-typed method would clear a cache on **every** SDR domain type" | TRUE (all four extend `AbstractBaseEntity`; verified) |
| "**exactly one** `@RepositoryEventHandler` on `origin/develop`" (triage) | TRUE — `git grep -l "@RepositoryEventHandler" origin/develop -- src/main/java` returns one file |
| "`Itemdata` methods are **unreachable** today" | TRUE — see F4, including the POST axis |
| "the caches are keyed with a tenant prefix, so one cache instance holds **every** tenant's entries" | TRUE — every `@Cacheable` key begins `TenantKeyBuilder.cacheKey(TenantContext.getCurrentTenant())` |
| "SDR writes to these three resources are admin-console frequency" | Not verifiable from code; it is a judgement, correctly not presented as a measurement |

**No false completeness claim found.** Given the repo's history this is worth recording as the
exception rather than the rule.

---

## C. Gaps — what could still be wrong in production

### C.0 First, new evidence that *shrinks* the biggest stated gap

The author writes: *"Neither proves the running Spring Boot application creates the bean — that needs
the full application context, which does not start in the unit lane."* True of the commit. But an
instrument for the container half does exist, and it is a DB query nobody ran:

```sql
SELECT channel, count(*), min(changed_at), max(changed_at)
FROM putaway_config_audit GROUP BY channel;
```

on `dev_wh01_om1`:

```
migration  8803   2026-08-11
typed         6   2026-08-13 .. 2026-08-28
hal           1   2026-08-26 17:10:52 UTC
```

`CHANNEL_HAL` is written **only** by `PutawayConfigService.auditAndEvict(...)`, which is reachable
**only** from `PutawayConfigRepositoryEventHandler`'s `@HandleAfter*` methods. That single `hal` row is
therefore live proof that, in a deployed container, Spring Data REST post-processes a
`@Component @RepositoryEventHandler` bean sitting in `net.aim_ai.wms.config` and dispatches an After
event to it. It does not prove *this* bean is created — but it converts the author's
"same instantiation phase as the already-proven handler" from an argument into an argument resting on
*measured* precedent, which is what §Q1.E of the architect consult asked for and could not find. The
residual is now only "is this specific `@Component` scanned and its `CacheManager` injectable", and a
failure of either fails the boot loudly rather than silently. **Worth adding to the evidence file.**

### C.1 Prioritised residual risks

| # | Risk | Likelihood × impact | Notes |
|---|---|---|---|
| 1 | The bean is created but the fix is never observed end-to-end in a deployed build | low × high | Closed cheaply by the sysprop re-probe in **M1**. C.0 already lowers the likelihood a lot. |
| 2 | Read-through re-warm race: reader misses, starts its SELECT, writer commits and `clear()`s, reader stores the pre-commit row after the clear | **medium × low** | Real, ~one query round-trip, and correctly stated as not closed. It is the honest residual; no evict-after-write scheme closes it. Reduced from a 2–5 min TTL to single-digit ms — a genuine win, not a fix. |
| 3 | OSIV or an outer `@Transactional` is added around the SDR path, silently inverting the post-commit property | low × high | **Nothing goes red if this happens.** The tripwire is prose in a javadoc. A one-line unit test asserting `spring.jpa.open-in-view=false` in `application.properties` would make it a red instead of a comment — the repo already does exactly this for `StartApplicationAutoConfigurationExclusionUnitTest`. Cheapest real hardening available. |
| 4 | Someone adds a second `CacheManager` bean | low × medium | Constructor injection is by type with no `@Qualifier`. Fails the boot loudly (the author already hit the two-candidate failure from the test side), so it is a loud failure, not a silent one. Acceptable. |
| 5 | `redis` profile enabled → `clear()` becomes a blocking `KEYS` over the whole keyspace, once per SDR write | very low × high | Correctly identified, documented in the javadoc, latent (profile activated nowhere). Out of scope. |

### C.2 Adjacent write paths — I checked, and they are **not** gaps

Recording these so the next reader does not re-derive them:

- `UtilRestController` performs ~20 uncommented `locationRepository.save(loc)` calls with no eviction —
  but the class is `@Service`, not `@RestController`, so its `@RequestMapping` methods do not route.
  Dead.
- `SkuBatchCreateUpdateService.upsertAll` saves `Itemdata` with no `@CacheEvict` of its own — but its
  only caller, `SkuRestController`, evicts programmatically in a `finally` block, deliberately.
- The `@Order(HIGHEST_PRECEDENCE)` ordering change means the putaway audit now runs *after* our
  `clear()`. I checked whether it re-warms what we just cleared: `subjectLabelFor` uses
  `itemdataRepository.findById` / `clientRepository.findById` — the **repositories**, not the
  `@Cacheable` services. Nothing re-warms. Benign today, one refactor from breaking → **L2**.

---

## Findings

### M1 — the skipped acceptance item's rationale does not cover the whole item (Medium, evidence/process)

The capacity argument is correct for `client` and `location` and I verified its premises (F6). It does
**not** apply to `sysprops`, which the same analysis certifies as confound-free:

> "`sysprops` being *under* capacity is the reason the 2026-08-31 live sysprop measurement is
> trustworthy."

A post-deploy `PATCH /v3/sysprop/{id}` → `GET /v3/system/mobileUiUrl` on dev is ~5 minutes, has no
capacity or TTL confound by the author's own reasoning, reproduces the exact pre-fix measurement, and
is the only cheap instrument that touches both the real SDR route and the container half at once. The
evidence file's §"Live probe for client / location — deliberately NOT run" frames the whole acceptance
item as confounded; one third of it was not.
**Recommendation:** run the sysprop re-probe once `4d3000fd` is on dev, and amend the evidence file to
say the capacity rationale covers `client`/`location` only.

### M2 — the free container-side tripwire was not armed (Medium)

The author correctly names the container half as the residual gap, then does not take the zero-cost
mitigation. `PutawayResolverContextLoadTest` already exists as the repo's DI hard gate for exactly
this kind of bean and already `@Autowired`s `PutawayConfigRepositoryEventHandler`. Adding

```java
@Autowired private SdrCacheEvictionEventHandler sdrCacheEvictionEventHandler;
```

costs one field and one assertion, and it arms automatically the day SBDEV-2217 restores that lane.
Stronger still, and still cheap: assert against the real `AnnotatedEventHandlerInvoker` bean's
`handlerMethods` map in that same test, which would prove registration in a container rather than
bean presence — the very weakness that test's current `isNotNull()` shape has and that the author
correctly criticises in the registration test's javadoc.

### L1 — the `cacheManager == null` branch is dead, and its javadoc justification names a test that does not exist (Low)

```java
if (cacheManager == null) {
    LOG.warn("no CacheManager wired — SDR eviction of cache={} skipped", cacheName);
    return;
}
```

The javadoc defends it as *"reachable only from a test that constructs this handler without one"*.
**No test does.** AC-13 supplies a manager whose `getCache` returns null (the null-*cache* branch);
AC-14 supplies a throwing mock. Nothing passes `null`. In production, constructor injection of a
required bean cannot yield null — it fails the boot. So the branch is unreachable and its stated
reason is false. PIT's `NegateConditionals` mutant on it is killed only incidentally (negation makes
every call return early, failing the twelve eviction tests), which is coverage of the *condition*, not
of the branch. Either delete it or add `new SdrCacheEvictionEventHandler(null)` to `Guards` and make
the javadoc true.

### L2 — the ordering change's coupling to the putaway audit is undocumented (Low)

`@Order(HIGHEST_PRECEDENCE)` now guarantees eviction runs *before* `auditAndEvictWarehouse` /
`auditAndEvictMerchant` / `auditAndEvictSku`. Those call `subjectLabelFor`, which today uses
`itemdataRepository.findById` / `clientRepository.findById`. If anyone switches those to the
`@Cacheable` service readers (`itemdataService.getById`, `ClientService.getByNumber`) — a natural-looking
tidy-up — the audit would re-warm the cache we just cleared, on the same request, and no test would go
red. The javadoc explains *why* `@Order` is needed; it does not record what the resulting ordering now
depends on. One sentence.

### L3 — the behavioural harness relies on surefire not running tests in parallel (Low)

`ClientHarness.clNr`, `sectionId`, `exists` and the equivalents on the other three harnesses are
**class-level mutable statics**, reset inside the `@Bean` factory methods. That is safe today: `pom.xml`
configures no `parallel` / `threadCount`, and there is no `junit-platform.properties`. Enabling JUnit
parallel execution — a plausible future speed-up on a 6007-test suite — would make these four nested
classes cross-contaminate. A comment saying the statics assume sequential execution is enough.

### L4 — two claims are true but under-derived (Low)

- **"+25 = the new tests"** is asserted where it is *provable*: the commit has 0 deletions across 3
  files, so no pre-existing test count could have moved. One clause turns an assertion into a proof.
- **"zero JPA association annotations"** is stated from reading the four entities. The repo already
  contains an independent measured enumeration in `RestConfiguration` ("exactly THREE association
  resources repo-wide — `User.groups`, `UserGroup.roles`, `UserRole.functions`"). Citing it gives the
  claim the two instruments this repo requires, for free. Also: the check must include
  `AbstractBaseEntity`, which the claim does not mention (it is clean — I verified).

---

## What I ran

| Instrument | Result |
|---|---|
| `mvn -o clean test` in `3176-review-b` | `Tests run: 6007, Failures: 0, Errors: 0, Skipped: 67` · `BUILD SUCCESS` |
| `mvn -o org.pitest:pitest-maven:mutationCoverage -DtargetClasses=…SdrCacheEvictionEventHandler -DtargetTests='…SdrCacheEviction*'` | `Generated 15 mutations Killed 15 (100%)` · `Mutations with no coverage 0` · `Test strength 100%` |
| `mcp__wms2-wineco-dev__execute_sql` × 4 | row counts; table-name discovery; `putaway_config_audit` channel breakdown (**C.0**) |
| `mcp__landlord-prd__execute_sql`, `mcp__landlord-dev__execute_sql` | 1 prd row; 1 of 4 dev rows active |
| Source reads | the handler, both test classes in full, `RestConfiguration` (withdrawal loop + `WRITE_VERBS` + kept-writable list), `CacheConfig`, `PutawayConfigRepositoryEventHandler` After phase, `PutawayConfigService.auditAndEvict*` + `subjectLabelFor`, the four entities + `AbstractBaseEntity`, `StartApplication`, `PutawayResolverContextLoadTest` |
| Not re-run | the pre-fix red (read the author's `3176-red.log`), the `92ca2e38` baseline (derived instead — see F1), the UAT landlord query, the jar sources cited by the architect consult |
