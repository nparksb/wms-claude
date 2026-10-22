---
title: SBDEV-1581 — re-review 3 of 93e4a2f6 (URLs from PROPERTY, lane wording, stronger pin)
date: 2026-10-19
reviewer: code-reviewer lane (read-only, no mvn run)
commit: 93e4a2f602237cd3353231ee148be6c943063dc1
prior-review: review-h2-isolation-2.md
worktree: .claude/worktrees/wms2-api/SBDEV-1581-h2
verdict: APPROVE (0 CRITICAL, 0 HIGH, 0 MEDIUM, 5 LOW; none blocking)
---

# Re-review 3 — 93e4a2f6

**Verdict: APPROVE.** 0 CRITICAL, 0 HIGH, 0 MEDIUM, 5 LOW. Every finding of review 2 that this commit
targeted is fixed and the new text is true. The Lows are residue and carry-overs.

Method: `git show 93e4a2f6`, then full reads of the base, the initializer, the pin test, `TestDatabaseConfig`,
the two SBDEV-3363 classes, `StartApplication`, and greps over `src/main` and `src/test`. No Maven run.
Measured results in the request (pin 3/3 green; constant-id mutant red with "two contexts must get different
database ids") taken as given.

## (1) Constant-expression annotation strings — OK

`BaseRollbackIntegrationTest.java:44,48`:
`"...rollback_tenant_${" + RollbackDatabaseNameInitializer.PROPERTY + "};DB_CLOSE_DELAY=..."`

- `PROPERTY` is `static final String PROPERTY = "wms.test.rollback-db-id";`, a literal-initialised constant
  variable. A qualified `Type.NAME` of a constant variable is a constant expression (JLS 15.29), and `+` on
  constant Strings is too, so it is legal as an annotation element value. Package-private access is fine:
  the base and the initializer are both in `net.aim_ai.wms.common.base`.
- Runtime value: `"${" + "wms.test.rollback-db-id" + "}"` folds to `${wms.test.rollback-db-id}`, byte-identical
  to the old literal placeholder. The surrounding text is unchanged in the diff. The mutation run (constant-id
  mutant caught) shows the file compiles and resolves.
- Side effect (positive): a rename of `PROPERTY` can no longer drift from the URLs.

## (2) Findings of review 2 — status

| Finding | Status |
|---|---|
| M-A false "cannot embed a constant" claim | FIXED, option 1: both URLs built from `PROPERTY`; the false sentence is gone and the javadoc now states the true rule. |
| L-A tenant-PU wording | FIXED. Names `TestDatabaseConfig`'s mock, says it is "a fact about this test lane, not about the application". Verified true, see (3). |
| L-B Advice / StockunitDamaged comments | FIXED. Both read `this context's rollback_landlord_<id> H2 database (SBDEV-1581)`. |
| L-C glyph on `ServiceLogPropagationIT` | FIXED. Glyph dropped. |
| L-C present tense in Cancel header; Deferred omission | NOT addressed, see L-1 below. |
| L-D pin did not call `initialize()` | FIXED: `eachContextGetsADifferentId`. |
| L-E `contains` anywhere | FIXED: `startsWith(key + "jdbc:h2:mem:rollback_<x>_" + placeholder + ";")`. |
| L-F long line in `CancellationReversalLockClear...` | FIXED (rewrapped; the paragraph is still ragged, cosmetic). |
| M3, L1, OQ1, M2.7 carry-overs | Explicitly not in this commit. See L-5. |

## (3) Truth of new javadoc and comments

`RollbackDatabaseNameInitializer` class javadoc, paragraph 2, checked claim by claim:
- "`StartApplication` excludes `DataSourceAutoConfiguration`": TRUE, `StartApplication.java:42-43`.
- "nothing reads `spring.datasource.url`": TRUE, `git grep spring\.datasource -- src/main` returns no hit.
- "`TestDatabaseConfig` replaces `tenantDynamicRoutingDataSource` with a mock whose connections come from
  `landlordDataSource`": TRUE. `TestDatabaseConfig.java`: `@Bean(name = "tenantDynamicRoutingDataSource") @Primary`
  returns `Mockito.mock(TenantDynamicRoutingDataSource.class)`; both `getConnection()` and
  `getConnection(anyString, anyString)` answer `landlordDataSource.getConnection()`. The bean overrides the real
  one because the base sets `spring.main.allow-bean-definition-overriding=true`.
- "so tenant entities land in the landlord H2 database too": TRUE, consistent with `TestDatabaseConfig`'s own
  `jdbcTemplate` javadoc ("the real H2 instance that also backs every tenant-package entity via that mock").
- "a fact about this test lane, not about the application": TRUE and appropriately scoped.
- `PROPERTY` javadoc "build their placeholder from this constant ({@code "${" + PROPERTY + "}"} is a
  compile-time constant expression)": TRUE.
- Advice / StockunitDamaged comments: TRUE. "Tenant JPA routes through TestDatabaseConfig's mock to this
  datasource" matches the mock.
- `BaseRollbackIntegrationTest` class javadoc: "BaseRollbackIntegrationTestDatabaseNamePinTest fails if the id
  is dropped from either" TRUE.
- `ServiceLogPropagationIT`: reworded text "since SBDEV-1581 it is no longer what protects the siblings" is
  consistent with its HISTORY block.
- `CancelOrderAlreadyCancelled...`: "would merge with AdviceServiceRollbackIntegrationTest's" still true (same
  three `@MockitoBean` types, per review 2).

No false statement found in the lines this commit touched.

## (4) Pin test — not vacuous

- `bothUrlsEmbedThePerContextId`: `startsWith(key + e[1])`, where `e[1]` is
  `jdbc:h2:mem:rollback_<tenant|landlord>_` + `${<PROPERTY>}` + `;`. That anchors the placeholder inside the
  database-name segment and requires the terminating `;`, so a placeholder moved to an option, or a name that
  trails extra text, fails. `filter(startsWith(key))` plus `isNotNull()` gives an attributable failure if a URL
  moves out of the annotation. Not vacuous.
- `eachContextGetsADifferentId`: asserts both ids non-blank and unequal, reading through the real
  `Environment`, so a constant-id mutant (measured red), a wrong-key mutant (blank), and a missing-publish mutant
  are all caught. A `GenericApplicationContext` that is never refreshed is a legitimate carrier for
  `ApplicationContextInitializer<ConfigurableApplicationContext>`: `getEnvironment()` and `addLast` work before
  refresh, and try-with-resources `close()` on an un-refreshed context is a no-op. No Spring Boot context and no
  I/O, so it is a plain unit test and `PinTest` is picked up by surefire (excludes are `*IntegrationTest` and
  `*E2ETest` only).
- Remaining blind spot (accepted): it does not prove the id ends up in a URL that Spring resolves; that is
  the forced-eviction run (`-Dspring.test.context.cache.maxSize=1`) named in the javadoc.

## Findings

### [LOW] L-1 — Cancel header still present tense; Deferred omission
File: `CancelOrderAlreadyCancelledPositionIntegrationTest.java:~84-96`:
`Every subclass shares those names, but NOT a Spring context` and
`They do NOT fix the shared-state problem for the other ~30 subclasses`
Confidence: MEDIUM.
The header says "the text below records why the override was added (pre-SBDEV-1581)", which covers it, but read
alone these sentences are false today. Also the header says it "would merge with AdviceServiceRollbackIntegrationTest's"
and never mentions that `DeferredCancelTerminalPathIntegrationTest` would join the same context if its override
went (its own header does not cross-reference this). Fix: past-tense those two sentences ("shared", "did not
fix") and add "(as would DeferredCancelTerminalPathIntegrationTest's)".

### [LOW] L-2 — new/changed lines exceed the file's ~120-col wrapping
Files: `BaseRollbackIntegrationTestDatabaseNamePinTest.java:48` (125, new in this commit; lines 58 and 61 are
older at 133 and 126), `RollbackDatabaseNameInitializer.java:14` (121, and the paragraph now wraps raggedly:
"Measured on SBDEV-1581: reverting only" then a short line).
Confidence: HIGH. Cosmetic. Re-wrap the paragraph and split the `.as(...)` message. The two 165/174-col
annotation lines in the base are inherent to a single URL string; splitting with `+` on a line break would also
work now that concatenation is legal.

### [LOW] L-3 — base class javadoc still says it provides tenant H2 datasources
File: `BaseRollbackIntegrationTest.java:~26-28`:
`Provides H2 in-memory datasources for both landlord and tenant via @TestPropertySource`
Confidence: LOW-MEDIUM.
Pre-existing, but it now contradicts the initializer javadoc this commit sharpened: only the landlord URL
reaches a live pool, and the tenant one is read by nothing. Fix: "...for the landlord (live) and, for
symmetry, the tenant URL (read by nothing in this lane; see RollbackDatabaseNameInitializer)".

### [LOW] L-4 — first pin test is now partly tautological about the placeholder
File: `BaseRollbackIntegrationTestDatabaseNamePinTest.java:~35-50`
Confidence: LOW (observation). Since the URLs are built from `PROPERTY`, the placeholder text cannot drift from
the constant, so the test's value is the name-segment shape and the `;` terminator, which it does check. The
javadoc ("a URL that stops embedding the id") remains accurate. No change needed; mention so a later reader does
not delete the reflection and the test with it.

### [LOW] L-5 — carry-overs from reviews 1 and 2 are still open and unrecorded
Confidence: HIGH that they are open; they are not regressions.
- M3: the `wms_integration` lane shares fixed names in `application-integration.properties`. Needs a proposal on
  the ticket (per the findings-go-on-the-ticket policy), not silence.
- L1: SBDEV-3363 fixed literals (`_3363`, `_3363ac5`) keep the old hazard for a copy with a different mock set;
  hardening is `rollback_landlord_3363_${...}` built from `PROPERTY`, now trivially possible.
- OQ1: committed rows no longer wiped by other contexts' creation; gate on the full suite, and re-run the unit
  lane once after this commit's added unit test.
- M2.7: the external memory file `wms2-baserollback-shared-h2-create-drop.md` is stale; mark FIXED with the SHA
  after merge.

## Positive observations
- The M-A fix took the stronger option (derive, not duplicate) and deleted the false justification outright.
- The new behavioural unit test is cheap, mutation-checked (constant-id mutant red with the intended message),
  and uses a legitimate lightweight context.
- The new wording separates a fact about the test lane from a fact about the application, and every clause is
  verifiable against `StartApplication`, `TestDatabaseConfig` and a grep of `src/main`.
- Review-2 L-B, L-D and L-E were fixed in the same push as the MEDIUM.

## Recommendation
**APPROVE.** Optionally fix L-1 and L-2 in the same push; record L-5 on the ticket before merge.
