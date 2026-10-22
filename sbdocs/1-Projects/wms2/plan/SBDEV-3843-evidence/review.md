---
ticket: SBDEV-3843
kind: review
reviewer: code-reviewer (independent lane, read-only)
date: 2026-10-20
scope: git diff origin/develop...HEAD (f19b8a45, e13801b4, df90a857) in .claude/worktrees/wms2-api/SBDEV-3843
---

# SBDEV-3843 code review

**Verdict: COMMENT.** Nothing blocking at HIGH confidence. Mechanism verified against the 3.5.9 sources. One MEDIUM needs the default-cache full-suite result (it is running) before merge. Five LOWs, all comment/robustness.

Counts: CRITICAL 0 · HIGH 0 · MEDIUM 1 · LOW 6

## Stage 1: spec compliance
Matches the ticket. Both `application-integration.properties` URLs embed `${wms.test.rollback-db-id}`. The initializer is registered globally through `src/test/resources/META-INF/spring.factories`. There is a structural pin and a behavioural pin. The change is test-only and touches no `src/main`.

## Mechanism checks (Q1). Verified, no defect
- **The factory initializer reaches every Boot test context.** In `spring-boot-test-3.5.9-sources.jar` `SpringBootContextLoader.getInitializers` (L344-358), `initializers.addAll(application.getInitializers())` collects the `spring.factories` instances that the `SpringApplication` constructor loaded. The `@ContextConfiguration` classes are added after them, and `application.setInitializers(initializers)` follows (L246). The slices (`@WebMvcTest` in `TenantPoolEndpointSecurityTest`, `@DataJpaTest`, etc.) use the same loader, so they get it too. `PostgresIntegrationLaneDdlAutoPropertyUnitTest:147` (`new SpringApplicationBuilder(...)`) also gets it. That is harmless: it only adds a property.
- **Cache key unchanged.** Factory-loaded initializers are not part of `MergedContextConfiguration`. Only `getContextInitializerClasses()` is, so no test gets a new context.
- **BaseRollbackIntegrationTest runs it twice.** The factory instance runs first, then the `@ContextConfiguration` one. `MutablePropertySources.addLast` calls `removeIfPresent` first (verified with javap on spring-core 6.2), so the second `MapPropertySource("rollbackDatabaseName")` **replaces** the first and does not duplicate it. Placeholders resolve at bean creation, which is after `applyInitializers`. So both URLs see the same (second) id, and the id is consistent within a context.
- **PG lane and the `@DynamicPropertySource` ITs** (`ReplenishClaimIT:124`, `ReplenishOrderJobClaimIT:107`, `MobileReplenishSourceScanIT`, `MobileReplenishMultiUnitLoadIT`) override both URLs outright. The placeholder is never read and the extra property source is inert.
- **Plain (non-Boot) Spring contexts** are `@SpringJUnitConfig`: `UserServiceTransactionBoundaryTest`, `UserRoleServiceTransactionBoundaryTest`, `UserGroupServiceTransactionBoundaryTest` and `CacheConfigTest`. None of them is on the `integration` profile, so not having the initializer is fine. Nothing in `src/test` combines plain `@ContextConfiguration` with `@ActiveProfiles("integration")`.
- **The `DelegatingApplicationContextInitializer` claim is true.** It is present in `spring-boot-2.3.7.RELEASE.jar` and absent from `spring-boot-3.5.9.jar`. The 3.5.9 `spring.factories` initializer list is ConfigurationWarnings, ContextId, ProtocolResolver, RSocketPortInfo and ServerPortInfo.

## Q2: context test soundness
- It extends `BaseRepositoryIntegrationTest` and declares no `@MockitoBean`, `@Import`, `@TestPropertySource` or nested `@Configuration`, so it joins the existing context. Correct.
- `SELECT DATABASE()` is H2's current-database-name function, and it works in `MODE=PostgreSQL`. `isEqualToIgnoringCase` covers `DATABASE_TO_LOWER` and the default upper-casing. The id is lowercase hex anyway. The mutant measurement (red without the factory line) shows the test discriminates.
- The pin test's `getResourceAsStream("/META-INF/spring.factories")` returns the **first** classpath hit. Under surefire, `test-classes` comes first, and `src/main/resources/META-INF` has no `spring.factories`, so today it reads the right file. See LOW-3 for the ordering fragility. It fails in the red direction only.

## Q3: reliance on a shared `wms_integration`
A grep of `src/` for `wms_integration` finds only the six edited files, all comments or the URLs themselves. No `DriverManager` or `jdbc:h2:mem:wms_integration` literal reaches across contexts. Cross-context seeding could never have worked reliably anyway, because each new context's create-drop wiped the shared DB. The inverse dependency is real, though. See MEDIUM-1.

## Findings

### [MEDIUM] Hidden reliance on the old cross-context wipe is not covered by the maxSize=1 measurement
- **Files:** `src/test/resources/application-integration.properties:20,31`
- **Confidence:** MEDIUM
- **Issue:** Under the old fixed name, creating any new integration-profile context ran `create-drop` on the shared DB. That incidentally **emptied** rows committed by earlier classes on other, still-cached contexts. Here is the scenario, with a default cache size (32) and no evictions:
  1. Class X on context A commits rows (no rollback, e.g. `BaseRepositoryIntegrationTest` subclasses that commit, per the "repo tests COMMIT" trap).
  2. Class Y needs context B. B's startup used to wipe the DB.
  3. Class Z runs on A again. Before the fix Z saw empty tables. Now Z sees X's rows, and a unique-key seed collides (the `UNIT_LOAD` collision documented in `MobileTransferOrderServiceIntegrationTest:620-640` is exactly this class of bug).

  `-Dspring.test.context.cache.maxSize=1` cannot expose this. A is evicted when B is created, so Z always gets a fresh DB.
- **Fix:** Gate the merge on the **default-cache** full suite (the run in progress), compared with the develop baseline. It is better still to run it twice, with `-Dfailsafe.runOrder=alphabetical` and `reversealphabetical`. Any new reds there are collisions this change unmasked, not regressions in the classes themselves.

### [LOW] Properties comment names a class that does not exist
- **File:** `src/test/resources/application-integration.properties:17`. Snippet: `# Pinned by IntegrationProfileDatabaseNamePinTest and IntegrationProfileDatabaseNameContextTest.`
- **Confidence:** HIGH
- **Issue:** The class is `IntegrationProfileDatabaseNameContextIntegrationTest`. A grep for the cited name returns nothing, so a maintainer may conclude the behavioural pin was deleted.
- **Fix:** Change the name to `IntegrationProfileDatabaseNameContextIntegrationTest`.

### [LOW] RollbackDatabaseNameInitializer javadoc and naming still describe only the rollback lane
- **File:** `src/test/java/net/aim_ai/wms/common/base/RollbackDatabaseNameInitializer.java:11`. Snippet: `SBDEV-1581 — gives every {@link BaseRollbackIntegrationTest} application context its OWN H2 database.`
- **Confidence:** HIGH
- **Issue:** It now runs for **every** Spring Boot test context through `spring.factories`, and the `integration` profile's URLs depend on it. The javadoc gives no hint that deleting or renaming it, or the `PROPERTY` constant, breaks 53 classes, not just the rollback lane. The `PROPERTY` javadoc says it is "Embedded by both datasource URLs in BaseRollbackIntegrationTest" and does not mention `application-integration.properties`. The `rollback-db-id` / `rollbackDatabaseName` names are now misleading too.
- **Fix:** Add a paragraph: "SBDEV-3843: also registered globally in `src/test/resources/META-INF/spring.factories`, and `application-integration.properties` embeds the same placeholder in both URLs. Running twice for BaseRollbackIntegrationTest is harmless, because `addLast` replaces the same-named source." Extend the `PROPERTY` javadoc the same way. Renaming is optional. If you rename, both pins read the constant reflectively, which helps.

### [LOW] Pin test reads the first `META-INF/spring.factories` on the classpath
- **File:** `src/test/java/net/aim_ai/wms/unit/config/IntegrationProfileDatabaseNamePinTest.java:57`. Snippet: `load("/META-INF/spring.factories").getProperty("org.springframework.context.ApplicationContextInitializer")`
- **Confidence:** MEDIUM
- **Issue:** `Class.getResourceAsStream` returns the first match. Surefire orders `test-classes` first, so it is correct today. Under a classpath that puts a dependency jar first (some IDE run configs, a future `additionalClasspathElements`), it reads spring-boot's own file. That file has an `ApplicationContextInitializer` key without our class, so the test goes falsely red. It cannot go falsely green.
- **Fix:** Assert on what Spring actually loads: `SpringFactoriesLoader.forDefaultResourceLocation(getClass().getClassLoader()).load(ApplicationContextInitializer.class)` (or `loadFactoryNames`) contains `RollbackDatabaseNameInitializer`. That is order-independent and tests the real mechanism. Alternatively, iterate `getResources(...)` and pick the URL under `test-classes`.

### [LOW] Context test ignores `rs.next()` and leaks the Statement until connection close
- **File:** `src/test/java/net/aim_ai/wms/integration/config/IntegrationProfileDatabaseNameContextIntegrationTest.java:51-53`. Snippets: `connection.createStatement().executeQuery("SELECT DATABASE()")` and `rs.next();`
- **Confidence:** HIGH
- **Issue:** If `next()` were false, the failure would be an opaque `SQLException` rather than an assertion. The Statement is not in the try-with-resources. It is closed when the connection closes, and Hikari reset handles it, so the effect is cosmetic.
- **Fix:** Use `try (Connection c = ...; Statement s = c.createStatement(); ResultSet rs = s.executeQuery(...))` and `assertThat(rs.next()).isTrue();`.

### [LOW] An unresolved placeholder degrades silently to the old shared DB
- **File:** `src/test/resources/application-integration.properties:20,31`
- **Confidence:** MEDIUM
- **Issue:** As measured on the first attempt, a context on this profile that lacks the initializer (a future plain `@SpringJUnitConfig` with `@ActiveProfiles("integration")`, or someone deleting the factory line) binds the literal `wms_integration_${wms.test.rollback-db-id}`. That literal is again a shared name, and nothing fails at startup. The context IT catches this only for the `BaseRepositoryIntegrationTest` context.
- **Fix:** Optional. Add a fail-fast guard: a tiny `@Component` in `TestDatabaseConfig`, or a check in `LockReadRail`-style customizer code, that throws if `landlord.datasource.jdbc-url` contains `${`. Otherwise accept it as covered by the two pins.

### [LOW] Redundant `@ContextConfiguration(initializers = RollbackDatabaseNameInitializer.class)` on BaseRollbackIntegrationTest is now undocumented
- **File:** `src/test/java/net/aim_ai/wms/common/base/BaseRollbackIntegrationTest.java:37`
- **Confidence:** HIGH
- **Issue:** It is functionally redundant with `spring.factories`, and it is part of that lane's cache key. It is harmless and pinned by `BaseRollbackIntegrationTestDatabaseNamePinTest:59`. A reader may "clean it up" (fine) or copy it to other bases thinking it is required (also fine but noisy).
- **Fix:** Add a one-line comment, "kept explicit; also arrives via spring.factories since SBDEV-3843", or drop both it and its pin. Not both halves.

### Comment truth audit (Q4)
- `ApplicationCacheResetTestExecutionListener`: true. With per-context DBs, a new context no longer resets a cached context's schema. The caches are context beans; no `static` Caffeine caches in `src/main`.
- `MobileTransferOrderServiceIntegrationTest:623,635`: true. The two classes share a cache key and therefore one id, and the rollback lane is still a distinct instance.
- `StockrecordViewHalContextTest:36`: true.
- `spring.factories` header: true ("contexts that do not use the placeholder ignore it" was verified above).
- `application-integration.properties` block: true, except the misnamed class (LOW-1).
- The pin test's measurement prose, "33 of the 53 classes failed (73 errors, 1 failure)", is consistent with the brief (74 errors+failures). Not re-measured, because mvn is disallowed in this lane.

## Positive observations
- It uses the right mechanism (`spring.factories`). The author measured that `context.initializer.classes` is ignored and pinned against regressing to it.
- It pairs a structural pin with a behavioural pin, and the mutant (no factory line) turns both red.
- It reuses the existing initializer instead of a second one, and its placeholder-not-`${random.uuid}` rationale carries over correctly.
- Comment edits keep the original diagnosis and mark it historical rather than deleting it.

## Not done in this lane
- No `mvn` and no `lsp_diagnostics` run (the worktree suite is live). The diff is simple and its imports resolve by inspection.
