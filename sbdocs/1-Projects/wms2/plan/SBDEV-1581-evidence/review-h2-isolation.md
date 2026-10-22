---
title: SBDEV-1581 — independent review of 848de7c8 (per-context H2 names for BaseRollbackIntegrationTest)
date: 2026-10-19
reviewer: code-reviewer lane (read-only, no mvn run)
commit: 848de7c89b78a20d73bed53a6c69bace82a75857
worktree: .claude/worktrees/wms2-api/SBDEV-1581-h2
verdict: APPROVE (with doc follow-ups)
---

# Review — 848de7c8 `RollbackDatabaseNameInitializer`

**Verdict: APPROVE.** Nothing at HIGH severity with HIGH confidence. The mechanism is correct for
Spring Boot 3.5 / Spring 6.2. The cache-key topology does not change, and nothing in the tree depends
on two contexts sharing the DB. Findings: 0 CRITICAL, 0 HIGH, 3 MEDIUM, 6 LOW, plus 1 open question.
Most of them are stale comments that now state a false claim. Fix them on this ticket, in this PR.

Evidence was gathered read-only: `git show`, grep across the 40 subclasses and `src/main`, and
`gh run view --attempt 1 --log-failed` for the two develop runs cited in the commit. No Maven run.

## Stage 1 — spec compliance

| Ask | Status |
|---|---|
| Stop one evicted context's `create-drop` dropping the schema under the other contexts | Met. Every context creation gets a fresh id, so its DB is private (but see M1: only the landlord URL is live) |
| Classes that shared a context still share one | Met. The initializer class is part of `MergedContextConfiguration` and is identical for all 40 subclasses. The raw inlined property string, placeholder included, is identical too. Cache keys are unchanged |
| No collateral on the SBDEV-3363 private-name classes | Met. Their `@TestPropertySource` values win and never reference the placeholder |

## Q1 — does `@ContextConfiguration(initializers=…)` combine with `@SpringBootTest(classes=…)`?

**Yes.** `SpringBootTestContextBootstrapper.resolveContextLoader` copies `@SpringBootTest.classes` into
each `ContextConfigurationAttributes`, so a `@ContextConfiguration` that declares only initializers
does not lose `StartApplication`. `SpringBootContextLoader` instantiates
`mergedConfig.getContextInitializerClasses()` and adds them to the `SpringApplication`. They run in
`prepareContext`, after the environment (including `@TestPropertySource`) is built and before refresh.
`@TestPropertySource` and `@Import` on the base are independent annotations and merge as before.

Subclass sweep (all 40 `extends BaseRollbackIntegrationTest`). Grep for `@ContextConfiguration`,
`@ContextHierarchy`, `@BootstrapWith`, `@SpringBootTest`, `@DynamicPropertySource`, `inheritInitializers`:
- **No subclass declares `@ContextConfiguration`, `@SpringBootTest`, `@ContextHierarchy` or `@BootstrapWith`.**
  Nothing can set `inheritInitializers=false` or replace the bootstrapper.
- `@TestPropertySource` appears only in `CancelOrderAlreadyCancelledPositionIntegrationTest:98` and
  `DeferredCancelTerminalPathIntegrationTest:73`. Both use `inheritProperties` (the default) and only
  override the two URLs.
- `@Import` appears only in `NestedSendAfterCommitIT:61`. It is additive.
- `@DirtiesContext(AFTER_CLASS)` appears only in `ClubLineRetryIntegrationTest:34`. The context closes
  and drops only its own DB, which is now harmless to the others (before the fix it was an eviction
  that hit everyone).
- `@Nested` appears in `AdviceOutboxIntegrationTest` (159/217/277) and
  `CancellationReversalLockClearIntegrationTest:1304`. `@NestedTestConfiguration` defaults to INHERIT,
  so they get the enclosing class's config, initializer included.

Approximate grouping by bean-override set: about 18 distinct contexts. 21 classes share the
no-extra-override context. The 4 `CancellationReversal*` / `CancelPreservesGoodsOut*` classes share
one. `ServiceLogPropagationIT` and `MessageServiceSingleRowIT` share one. Neither the grouping nor the
count changes with this commit.

## Q2 — placeholder resolution

- `landlord.datasource.jdbc-url` is bound by `@ConfigurationProperties("landlord.datasource")` on
  `LandlordDatabaseConfig.landlordDataSource()` (`src/main/.../landlord/config/LandlordDatabaseConfig.java:37`).
  Boot's `Binder` resolves `${…}` through `PropertySourcesPlaceholdersResolver` at bind time, which is
  during refresh, after the initializer. Whether the source is added with `addLast` or `addFirst` does
  not matter, because no other source defines the key.
- **No raw reader exists.** `src/main` has no `getPropertySources()`, no `DataSourceProperties` and no
  `@Value` on either URL. `TestDatabaseConfig` (`src/test/.../common/config/TestDatabaseConfig.java`)
  takes the already-bound `landlordDataSource` bean and never reads a URL.
- **`spring.datasource.url` is read by nothing.** `StartApplication:43` excludes
  `DataSourceAutoConfiguration`, and `grep -rn 'spring\.datasource' src/main` returns zero hits. Tenant
  JPA goes through `TestDatabaseConfig`'s mocked `TenantDynamicRoutingDataSource` to `landlordDataSource`.
  See M1.

## Q3 — does anything rely on two contexts sharing the DB?

Code dependencies: **none found.** No test hard-codes `jdbc:h2:mem:rollback_*` in a `DriverManager`
call or anywhere else in code. All remaining hits are comments, listed below. Within one context the
data-sharing behaviour is unchanged. What changes is that a create in another context no longer wipes
data mid-run. That is open question OQ1.

## Findings

### [MEDIUM] M1 — only the landlord URL is live. The tenant URL is dead config, so "own pair of H2 databases" overstates what happens
Confidence: HIGH that `src/main` never reads `spring.datasource.*`. MEDIUM that no Boot auto-config reads it either: `DataSourceAutoConfiguration` is excluded and `DataSourceProperties` is never bound.
- `BaseRollbackIntegrationTest` javadoc: *"Each application context gets its OWN pair of H2 databases"*
- `RollbackDatabaseNameInitializer` javadoc: *"gives every … context its OWN pair of H2 databases"*
- Commit message: *"this commit with only the two URLs reverted: 7 run, 4 errors"*. Reverting only the landlord URL should give the same result.

Scenario: a later maintainer "simplifies" by templating only the tenant URL, thinking either one is
enough, and the bug comes back. Or someone reads `rollback_tenant_<id>` as the DB that holds the
tables. The tables live in `rollback_landlord_<id>`, as `AdviceServiceRollbackIntegrationTest:89-90`
and `StockunitDamagedRollbackIntegrationTest:106-107` already say.
Fix: in both javadocs, state that the landlord URL is the load-bearing one, because
`TestDatabaseConfig`'s routing mock sends tenant JPA there. Keep the tenant placeholder for symmetry,
or drop the dead `spring.datasource.*` lines.

### [MEDIUM] M2 — stale comments that are now false (the change should fix them in the same PR)
Confidence: HIGH.
1. `src/test/java/net/aim_ai/wms/integration/ServiceLogPropagationIT.java:66-84`. Line 68-69: *"`BaseRollbackIntegrationTest` points all 39 of its subclasses at the shared `jdbc:h2:mem:rollback_tenant`"*. Line 83-84: *"If you add a mock, an @Import or a property override here, you will reintroduce the failure in a class that has nothing to do with this one."* Both are now false. There are 40 subclasses, no shared name, and the shared DB was `rollback_landlord`, never `rollback_tenant`. An extra context now causes an eviction but not a drop under others. Keep the CI-run history (lines 76-80) as history and reword the warning: an identical mock set with `MessageServiceSingleRowIT` is now only a context-count or startup-time optimisation.
2. `src/test/java/net/aim_ai/wms/integration/CancelOrderAlreadyCancelledPositionIntegrationTest.java:71-97`. Line 72: *"PRIVATE H2 DATABASES, and this is load-bearing — do not delete"*. Line 74: *"BaseRollbackIntegrationTest pins two FIXED database names"*. Lines 91-93: *"They do NOT fix the shared-state problem for the other ~30 subclasses; the real fix is per-class names on the base, which is a separate change."* All three are false after 848de7c8. Either delete the override and the block (see L1), or reword to "historical; superseded by SBDEV-1581". Keep the `ddl-auto=update is NOT that fix` measurement, which is still true.
3. `src/test/java/net/aim_ai/wms/integration/DeferredCancelTerminalPathIntegrationTest.java:68-71`: *"BaseRollbackIntegrationTest pins shared database names with create-drop … New subclasses declare their own."* Now false, and it tells new subclasses to copy a pattern that is no longer needed.
4. `src/test/java/net/aim_ai/wms/smoke/PutawayResolverContextLoadTest.java:41`: *"({@code landlord.datasource.jdbc-url=jdbc:h2:mem:rollback_landlord})"*. The literal is stale. The point (the URL comes from the base, not from `application-integration.properties`) is still true.
5. `src/test/java/net/aim_ai/wms/integration/service/mobile/MobileTransferOrderServiceIntegrationTest.java:633` (*"pins {@code landlord.datasource.jdbc-url=jdbc:h2:mem:rollback_landlord}"*) and `:665` (*"lives in the {@code rollback_landlord} database"*). The literal is stale. The conclusion (a different instance from `wms_integration`) is still true, and is now stronger.
6. `src/test/java/net/aim_ai/wms/integration/service/CancellationReversalLockClearIntegrationTest.java:1293-1297`: *"Why nested here, not its own class … created the shared MessageService-mock context BEFORE another context's eviction dropped the shared H2 schema"*. Accurate as history, but the rationale no longer constrains anything. Add "(pre-SBDEV-1581)".
7. Memory `/home/nampark/.claude/projects/-home-nampark-dev-wms-claude/memory/wms2-baserollback-shared-h2-create-drop.md`. Line 3 (description), 11-13, line 32-34 (*"Adding a subclass? Give it private database names"*) and line 42 (*"The real fix … unowned as of 2026-09-15"*) are all stale once this merges. Mark it SUPERSEDED or FIXED with the SHA. The file is also missing from the `MEMORY.md` index (grep found no entry), which already holds 201 of its 200 lines.

Not stale: `ApplicationCacheResetTestExecutionListener.java:16-27` and the `spring.factories` comment. They describe the `wms_integration` lane, which this commit does not touch (see M3).

### [MEDIUM] M3 — sibling sweep: the `wms_integration` H2 lane has the same structural defect
Confidence: MEDIUM. Same mechanism, but no CI red observed on that lane for this cause.
`src/test/resources/application-integration.properties:9,20,27,29` sets
`jdbc:h2:mem:wms_integration;DB_CLOSE_DELAY=-1` with `ddl-auto=create-drop`. It is shared by
`BaseIntegrationTest` (14 direct subclasses), `BaseRepositoryIntegrationTest` and `BasePerformanceTest`,
across contexts that differ by bean overrides.
`ApplicationCacheResetTestExecutionListener:16-27` already documents a schema re-create from a new
context hitting a cached context. Those lanes are `@Transactional`, so data leakage is masked, but an
eviction still drops the schema under the cached siblings.
Scenario: a new `@MockitoBean` in one `BaseIntegrationTest` subclass pushes the cache past 32. An
eviction then drops `wms_integration` while a sibling context is cached, and that sibling fails with
"this database is empty".
Fix: propose on this ticket (it is T1-sized). Attach the same initializer to the three bases and
template `wms_integration_${wms.test.rollback-db-id}` (rename the property generically, e.g.
`wms.test.h2-db-id`). Under the revised policy: put it on this ticket, or propose it.

### [LOW] L1 — the two SBDEV-3363 private-name overrides are now redundant, and their fixed literals keep the old hazard alive
Confidence: HIGH.
`CancelOrderAlreadyCancelledPositionIntegrationTest:98-101` (`rollback_*_3363`) and
`DeferredCancelTerminalPathIntegrationTest:73-76` (`rollback_*_3363ac5`).
Scenario: someone copies either class, property set included. The copy joins the same cache key and
DB, which is benign. A copy with a different mock set but the same literal brings back exactly the
cross-context drop.
Fix: delete both `@TestPropertySource` blocks.

⚠ Doing so changes the cache key. `CancelOrderAlreadyCancelled…` then joins
`AdviceServiceRollbackIntegrationTest`'s context (same mock set, per its own comment at line 86-89),
and data now accumulates in that context. Run the full suite after the removal; do not assume it.
If that is unwanted, keep the overrides and switch the literals to the placeholder plus a suffix,
e.g. `rollback_landlord_3363_${wms.test.rollback-db-id}`.

### [LOW] L2 — a missing initializer fails open to a shared fixed name
Confidence: MEDIUM. It depends on Boot's `Binder` ignoring unresolvable placeholders, which it does,
and on H2 accepting `${…}` in a mem DB name.
If a future subclass or meta-annotation drops the initializer (`inheritInitializers=false`, or a
copied `@TestPropertySource` onto a non-subclass), the URL binds literally as
`jdbc:h2:mem:rollback_landlord_${wms.test.rollback-db-id}`. That is again one name shared by every such
context, and the original bug silently returns.
Fix: add a one-line guard. For example, in the initializer, register a `BeanPostProcessor`, or add a
`@PostConstruct` check in a base-imported config, that asserts `landlordDataSource.getJdbcUrl()`
contains no `${`. A cheap alternative is a `contextLoads`-style assertion in one subclass.

### [LOW] L3 — the property name is duplicated as a literal
Confidence: HIGH. `RollbackDatabaseNameInitializer.PROPERTY` (*"Referenced by the two datasource URLs"*)
is not actually referenced: the annotation repeats `wms.test.rollback-db-id` as a literal. Annotation
values accept constant concatenation, so the base can use
`"…rollback_landlord_${" + RollbackDatabaseNameInitializer.PROPERTY + "};…"` and a rename cannot drift.

### [LOW] L4 — the commit message cites run ids whose current conclusion contradicts it
Confidence: HIGH. Today `gh run view 39283352255` reports `startup_failure` (attempt 2, no jobs).
`39291648188` is attempt 2 and was `in_progress` when this was written. The claimed failure is real,
but it is in **attempt 1** of each run. Verified: attempt 1 shows `Tests run: 936, Failures: 0, Errors: 4`.
The errors are `CancelPreservesGoodsOutFenceIntegrationTest` ×2 and
`CancellationReversalParcelSourceIntegrationTest` ×2, with `Table "los_sequencenumber" not found (this
database is empty)` (8 hits) and `Table "tenant_db_configuration" not found` (4 hits).
Fix: write "attempt 1 of runs …" in the PR body so a reader who opens the run is not misled.

### [LOW] L5 — the H2 instances are retained for the JVM lifetime (`DB_CLOSE_DELAY=-1`)
Confidence: HIGH. Negligible in practice.
Before the fix the family used 2 names. Now every context creation adds 2 names. Only the landlord
one is ever opened (M1), so in practice it adds 1. The family has about 18 distinct cache keys, plus
re-creations after evictions (JVM-wide cache, default maxSize 32, shared with the other families).
Expect at most a few dozen H2 instances. An evicted context's `create-drop` drops its tables on close,
leaving an empty shell of a few KB. Contexts still cached hold their schema, as they did before,
until the JVM shutdown hook closes them. The Spring contexts themselves dominate memory by orders of
magnitude.
Ordering hazard: none new. A re-created context gets a new id and a fresh schema, so it can never
attach to the dead DB of a previous incarnation.
Fix: none needed. Optionally add `;DB_CLOSE_ON_EXIT=TRUE` (the default) or drop `DB_CLOSE_DELAY=-1`.
The latter is risky, because the pool's `minimum-idle=1` is what keeps the DB alive. Leave as is.

### [LOW] L6 — the commit proof runs 3 classes, not the suite
Confidence: HIGH that this is a gap. The outcome is unknown until the running suites report.
The `maxSize=1` proof (7 run, 0 errors, with a revert-to-red control, which is good) covers the
eviction mechanism. It does not cover the behavioural change in OQ1. The full `-Pci` suite against the
known baseline is the gating instrument. It is running now; do not merge on the 3-class result alone.

## Open questions (surfaced, not blocking)

### [MEDIUM] OQ1 — cross-context data wipes no longer happen, so leftover data could surface within a shared context
Confidence: LOW.
Before the fix, any context creation in the family ran `create` on the shared DB, which wiped rows
committed by classes in other contexts. That incidentally reset data between classes of one context
whenever a different context was created between them. Now a context's DB is only ever reset by its
own creation, so classes sharing a context see each other's committed rows for the whole run.
The memory file records that, under `ddl-auto=update`,
`CancellationReversalLockClearIntegrationTest` failed with *"Query did not return a unique result: 2
results"* and `SkuRestControllerAtomicityIntegrationTest` failed "must leave the itemdata table empty".
- `SkuRestControllerAtomicity…`'s mock set `{MessageService, SyspropService}` is unique, so its
  context is private and now **more** isolated than before. Likely fine.
- `CancellationReversalLockClear…` shares a context with `…Destination`, `…ParcelSource` and
  `CancelPreservesGoodsOutFence…` (all `@MockitoBean MessageService` only). If its "2 results" residue
  came from one of those siblings rather than from another context, the fix could expose it.
  That depends on suite order.
Resolve with the full-suite run now in progress: compare against the baseline, and look specifically
for `NonUniqueResult` or "not empty" failures in those four classes and in the 21-class
no-override group (`PickingorderUnitloadPresetVersionSaveIT` is the only writer there).

## Positive observations
- Correct choice of an initializer-published id over `${random.uuid}`, which would be re-drawn on
  every resolution. The javadoc explains why.
- The cache-key topology is unchanged, so no context is created that did not exist before. This
  respects the constraint `ServiceLogPropagationIT` documents.
- The proof includes a revert control ("only the two URLs reverted → 4 errors"), so the green result is
  not vacuous.
- The javadoc names the reproduction recipe (`-Dspring.test.context.cache.maxSize=1`).
- The commit message root cause matches the CI log exactly (verified, attempt 1).

## Recommendation
**APPROVE** 848de7c8 as a mechanism. Before the PR is marked ready, in the same PR:
1. Fix M2 items 1-6 and mark the memory file (M2.7).
2. Correct the "pair" wording (M1) and use the constant (L3).
3. Gate on the full-suite result vs the baseline (L6/OQ1).

Then propose M3 (the `wms_integration` lane) on this ticket, and add L1/L2 if they are cheap.
