---
title: SBDEV-1581 — re-review of 8e4e9222 (review-fix commit on the per-context H2 names)
date: 2026-10-19
reviewer: code-reviewer lane (read-only, no mvn run)
commit: 8e4e9222284434de8819dd20584cf44a89baed72
prior-review: review-h2-isolation.md
worktree: .claude/worktrees/wms2-api/SBDEV-1581-h2
verdict: COMMENT (one wording fix needed; nothing blocking)
---

# Re-review — 8e4e9222

**Verdict: COMMENT.** 0 CRITICAL, 0 HIGH, 1 MEDIUM, 6 LOW. No blocking issue. The MEDIUM is a new false
sentence in a javadoc, which is the defect class this commit exists to remove. Fix it, along with the
wording in item 3, and this is an APPROVE.

Method: `git show 8e4e9222`, then reads of the base, the initializer, `TestDatabaseConfig`,
`LandlordDatabaseConfig`, `TenantDatabaseConfig`, `StartApplication`, the three classes whose context
grouping is claimed, the pom surefire excludes, and a grep sweep of `src/test` and `src/main`. No Maven
run. The measured mutation results in the request were taken as given and are cross-checked against the
javadocs below.

## 1. Are the prior findings addressed, and are the edited comments true?

| Finding | Status | Note |
|---|---|---|
| M1 "pair" wording | Addressed | Base and initializer javadocs now say "OWN H2 database". The initializer javadoc states that only the landlord URL is live. Matches the measurements (landlord-URL revert: pin red and IT 4 errors; tenant-URL revert: pin red, IT green). See item 3 for the wording of the reason. |
| M2.1 ServiceLogPropagationIT | Addressed | The "39 subclasses" and `rollback_tenant` claims are gone. History is kept and labelled. The "mock set kept identical" warning is correctly downgraded to a startup-time saving. |
| M2.2 CancelOrderAlreadyCancelled… | Addressed | Header changed to "redundant since SBDEV-1581, kept deliberately". The context-grouping claim is true (see below). |
| M2.3 DeferredCancelTerminalPath… | Addressed | "New subclasses do NOT need their own" is true. The grouping claim is true. |
| M2.4 PutawayResolverContextLoadTest | Addressed | Literal replaced by `rollback_landlord_<per-context id>`. |
| M2.5 MobileTransferOrderService… | Addressed | Both literals updated. The conclusion (different instance from `wms_integration`) is still true. |
| M2.6 CancellationReversalLockClear… | Addressed | "Pre-SBDEV-1581 history" added. |
| L2 missing initializer | Addressed by a pin test, not a runtime guard | Acceptable. The pin test is red when the initializer is removed (measured). |
| L3 constant duplicated | Partly addressed, and the justification is false | See M-A. |
| L4 attempt numbers | Addressed in the initializer javadoc and the commit message | |
| M3, L1, L5, L6, OQ1, M2.7 (memory file) | Not in this commit | Carry-overs. See the end. |

### Context-grouping claim (the "redundant ... would change context grouping" sentences) — verified TRUE

- `CancelOrderAlreadyCancelledPositionIntegrationTest` declares three `@MockitoBean` fields:
  `HttpRestService`, `SyspropService` and `MessageService`.
- `DeferredCancelTerminalPathIntegrationTest` declares the same three.
- `AdviceServiceRollbackIntegrationTest` declares `SyspropService`, `HttpRestService` and `MessageService`.
  It has no `@Import` and no `@TestPropertySource`.
- The cache key includes the merged `@TestPropertySource` entries. Today the two SBDEV-3363 classes each
  carry a private literal pair (`_3363` and `_3363ac5`), so each is its own context. Removing the block
  from either one makes its key equal to Advice's. Both comments are accurate.
- One omission: the Cancel comment says it "would merge with AdviceServiceRollbackIntegrationTest's" and
  does not say the Deferred class would join the same context. Cosmetic (L-C below).
- Caveat: this rests on the declared field types only. I did not check whether other subclasses also share
  that set, which would only widen the merge.

### Sweep for remaining false claims

`grep` over `src/test` for `rollback_tenant`, `rollback_landlord`, "shared H2", "FIXED database". Remaining
hits are either history, correctly framed, or the imprecise ones listed under L-A and L-B below. No new
false statement was found other than M-A.

## 2. BaseRollbackIntegrationTestDatabaseNamePinTest

Sound. Not vacuous.

- Surefire picks it up. The pom excludes only `**/*IntegrationTest.java` and `**/*E2ETest.java`, and the
  class name ends in `PinTest`. It sits in `unit/config`, with the other structural pins.
- Reflection: `PROPERTY` is a package-private `static final String`. The test is in another package, so
  `getDeclaredField` plus `setAccessible(true)` is the right way to read it. There is no module system in
  the way. The read is not constant-folded, because it goes through `Field`.
- The URLs are read from the `@TestPropertySource` declared on `BaseRollbackIntegrationTest` itself. A
  subclass override cannot mask it. If someone moves the URLs to a different mechanism, the first
  assertion fails with "must declare spring.datasource.url=", which is attributable.
- Messages name the key, the placeholder and the consequence. The registration test names the exact
  annotation to restore. The `inheritInitializers` assertion closes the `false` route.
- The javadoc claims match the measurements:
  - "a URL that stops embedding the id" → pin red for either URL (measured).
  - "initializer no longer registered" → pin red with "must carry @ContextConfiguration" (measured).
  - "no error to say so" → the IT showed 4 errors and no placeholder error (measured).
  - "the behavioural proof is the forced-eviction run" → consistent.

### [LOW] L-D — the pin test does not exercise `initialize()`
File: `BaseRollbackIntegrationTestDatabaseNamePinTest.java`
Confidence: MEDIUM.
A mutant that publishes a constant id (or the wrong key, if `PROPERTY` and the `put` ever diverge) passes
both pin tests and every normal IT run. Only a manual `-Dspring.test.context.cache.maxSize=1` run catches
it. Fix: add a third test that calls `new RollbackDatabaseNameInitializer().initialize(ctx)` on two
`GenericApplicationContext`s and asserts that both resolve `${PROPERTY}`, and that the two values differ.
It is about ten lines and needs no Spring Boot context.

### [LOW] L-E — the placeholder check is `contains` anywhere in the entry
File: `BaseRollbackIntegrationTestDatabaseNamePinTest.java`: `.contains(placeholder)`
Confidence: LOW.
`jdbc:h2:mem:rollback_landlord;DB_CLOSE_DELAY=-1;X=${wms.test.rollback-db-id}` passes the pin and shares one
name. Unlikely edit. Fix if cheap: assert the prefix `jdbc:h2:mem:rollback_landlord_` + placeholder (or a
regex on the name segment before the first `;`).

## 3. "the tenant persistence unit runs on the landlord H2 instance" — verified, wording is imprecise

What the code says:

- `StartApplication:42-45` excludes `DataSourceAutoConfiguration` and `HibernateJpaAutoConfiguration`.
  `grep spring\.datasource src/main` returns no hits, so nothing reads `spring.datasource.url`.
- `LandlordDatabaseConfig:37-40` binds `@ConfigurationProperties("landlord.datasource")` onto a
  `HikariDataSource`. That is the only pool created from a URL property.
- `TenantDatabaseConfig:118-128`: `tenantEntityManagerFactory` uses the bean `tenantDynamicRoutingDataSource`.
  In production that is the real routing datasource.
- `TestDatabaseConfig` (`@Import`ed by the base) replaces it with a `@Primary` Mockito mock of
  `TenantDynamicRoutingDataSource`. The mock's `getConnection()` and `getConnection(String,String)`
  answer from `landlordDataSource.getConnection()`.

So the sentence is true in the H2 rollback lane only, and only because of that test mock. The javadoc
reads as if it were a property of the application wiring, and it names the wrong mechanism ("not read
here" is accurate, but the reason the tenant unit lands on the landlord DB is never given).

### [LOW] L-A — suggested wording
File: `RollbackDatabaseNameInitializer.java`, class javadoc, second paragraph
Confidence: HIGH.
Replace the second paragraph with:

> Both base URLs embed the id, but only `landlord.datasource.jdbc-url` reaches a live pool. `StartApplication`
> excludes `DataSourceAutoConfiguration` and nothing in `src/main` reads `spring.datasource.url`.
> `TestDatabaseConfig` replaces `tenantDynamicRoutingDataSource` with a mock whose connections come from
> `landlordDataSource`, so in this lane tenant-package entities are created in the landlord H2 database as
> well. The tenant URL carries the id anyway so the two never disagree if that wiring changes. Measured on
> SBDEV-1581: reverting only the landlord URL reproduces the failure; reverting only the tenant URL does not.

Same two-clause fix is wanted in `BaseRollbackIntegrationTest`'s class javadoc if it ever says "tenant".
It currently does not, so no change there.

## Findings

### [MEDIUM] M-A — new false claim: "An annotation value cannot embed a constant inside a placeholder string here"
File: `RollbackDatabaseNameInitializer.java`:
`* Referenced by the two datasource URLs in {@link BaseRollbackIntegrationTest}. An annotation value
cannot embed a constant inside a placeholder string here, so the base spells it out;`
Confidence: HIGH.
It can. An annotation element value must be a constant expression, and a constant expression may contain
string concatenation of constant variables, including a qualified name `Type.NAME` (JLS 15.29).
`PROPERTY` is a `static final String` initialised from a literal, and `BaseRollbackIntegrationTest` is in
the same package, so `"...rollback_landlord_${" + RollbackDatabaseNameInitializer.PROPERTY + "};..."`
compiles. The prior review's L3 said exactly this. The commit declined the change and then justified the
choice with a claim that is wrong. The pin test is a fine second line of defence, but the comment now
misleads the next reader into believing the duplication is forced.
Fix, in order of preference:
1. Do what L3 asked: build both URLs from the constant. Then a rename cannot drift, and the first pin test
   shrinks to "both URLs reference the placeholder".
2. Keep the literal and say why honestly: "the base spells the name out so the URL stays readable in the
   annotation; the pin test keeps the two in step."

### [LOW] L-B — two sibling comments still give the old name
Files: `AdviceServiceRollbackIntegrationTest.java:90` (`so the table lives in rollback_landlord H2.`) and
`StockunitDamagedRollbackIntegrationTest.java:107` (`table lives in rollback_landlord H2.`).
Confidence: HIGH.
Both are still correct in substance (the landlord DB holds the tables) and now imprecise in name. Make them
`rollback_landlord_<id>`. They were the pointers the prior review used to explain M1, so they are the
likeliest comments for the next maintainer to read. Not in the commit's list of six, but within the same
sweep.

### [LOW] L-C — residual present tense inside the "historical" blocks
Files:
- `CancelOrderAlreadyCancelledPositionIntegrationTest.java`: below the new header the text still reads
  `Every subclass shares those names, but NOT a Spring context` and
  `They do NOT fix the shared-state problem for the other ~30 subclasses`. The header says "the text below
  records why the override was added (pre-SBDEV-1581)", which covers it, but the sentences themselves are
  now false if read alone.
- `ServiceLogPropagationIT.java`: the line `// ⚠ NO @Import, NO @TestPropertySource, NO extra @MockitoBean`
  keeps the warning symbol on a restriction that the next line says no longer protects anything. A warning
  glyph on a non-load-bearing rule trains readers to ignore the others.
- The Cancel comment does not say that the Deferred class would also join Advice's context if its override
  went.
Confidence: MEDIUM. Fix: past-tense the two sentences, drop the warning glyph, add one clause.

### [LOW] L-F — long inserted line
File: `CancellationReversalLockClearIntegrationTest.java` around line 1293: the inserted
`(Pre-SBDEV-1581 history: ...) As a separate {@code BaseRollbackIntegrationTest} subclass it` line runs well
past the file's 110-column wrapping. Cosmetic. Re-wrap.

## Positive observations
- Every one of the six listed stale comments was addressed, and the "redundant, kept deliberately" framing
  is accurate. Keeping the overrides is the right call: removing them changes context grouping and needs a
  full-suite run (and it avoids re-opening the question in OQ1 under time pressure).
- The pin test is cheap, runs in surefire, has attributable failure messages, and was mutation-checked in
  both directions plus a control. That is the standard this repo asks for.
- The initializer javadoc now carries a measurement ("reverting only the tenant URL does not reproduce")
  rather than an assertion.
- Run ids carry "attempt 1", so a reader who opens the run is not misled.

## Carry-overs from review 1 not in this commit (not regressions)
- **M3** (`wms_integration` lane has the same shared-name structure in `application-integration.properties`).
  Needs an explicit proposal on this ticket, not silence.
- **L1** (SBDEV-3363 fixed literals keep the old hazard for a copy with a different mock set). Deliberate;
  the new comments are honest about it. A cheap hardening is to switch the literals to
  `rollback_landlord_3363_${wms.test.rollback-db-id}`.
- **OQ1** (committed rows no longer wiped by other contexts' creation). Gate on the full suite; the stated
  8530 unit / 936 IT result on 848de7c8 is the right instrument, but it was run before 8e4e9222 added a unit
  test, so re-run unit once.
- **M2.7** the memory file `wms2-baserollback-shared-h2-create-drop.md` is outside this repo and is still
  stale. Mark it FIXED with the SHA when this merges.

## Recommendation
**COMMENT.** Fix M-A (prefer option 1) and L-A, ideally L-B and L-D in the same push. Then it is an APPROVE.
Re-run the unit lane once, since the commit added a unit test after the quoted 8530/0.
