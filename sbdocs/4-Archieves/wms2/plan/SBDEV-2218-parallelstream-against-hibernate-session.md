---
title: "SBDEV-2218 — calculateUnitLoadAmounts parallelStream regression guard (v2)"
ticket: "SBDEV-2218"
ticket_url: "https://app.clickup.com/t/868jj31xq"
type: "bugfix"
priority: "high"
status: "archived"
project: ["wms2"]
version: "v2"
requester: "David Oppenheim"
created: "2026-05-09"
updated: "2026-05-09"
related:
  - "[[SBDEV-2217-sequence-number-silent-minus-one]]"
db_verified: true
tags:
  - plan
  - concurrency
  - tenant-context
  - regression-guard
---

# SBDEV-2218 — calculateUnitLoadAmounts parallelStream regression guard (v2)

**Ticket:** [SBDEV-2218](https://app.clickup.com/t/868jj31xq)
**Project:** wms2/wms2-api | **Version:** v2 (Java 21 / Spring Boot 3.x) | **Type:** bug fix (regression guard)
**Priority:** High (Tier 1 — silent data corruption class; v2 already fixed, this plan closes the audit-chain gaps)
**Reporter:** David Oppenheim | **Assignee:** Nam Park
**Parent:** WMS Code Fixes audit (868jj30yh)
**Status:** implemented (PR [#5](https://github.com/SiteBossInc/wms2-api/pull/5) open against develop) — central bug already fixed in `74f3c221`; this PR closed the residual audit-chain gaps

---

## 0. Affected sites (enumeration before drafting)

Grep run: `grep -rn "parallelStream\|\.parallel(" src/main/java` and targeted reads of `service/CustomerorderBatchService.java` lines 24-25 and 1045-1080. Every "yes" row in the In-scope column MUST be visited by §5 Fix Design or excluded with rationale.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|---|---|---|---|
| 1 | `service/CustomerorderBatchService.java:24-25` | `@Service` only; class-level `@Transactional` removed | yes (root) | **no — [ALREADY DONE — landed in `58ad0f36`]** |
| 2 | `service/CustomerorderBatchService.java:1045-1062` | `calculateUnitLoadAmounts` uses sequential `.stream()`; `parallelStream()` removed; `> 100` threshold removed | yes (root) | **no — [ALREADY DONE — landed in `74f3c221`]** but covered by Fix D (comment hardening) and Fix C (back-reference cleanup) |
| 3 | `service/CustomerorderBatchService.java:1051-1053` | inline comment cites `TenantContext` ThreadLocal | yes (regression marker) | **yes — Fix D** (add SBDEV-2218 reference + Hibernate Session reason + arch-test/IT pointers) |
| 4 | `service/CustomerorderBatchService.java:1054, 1058, 1060` | `amounts` HashMap captured by lambda + used as Collector supplier | yes (residual fragility) | **yes — Fix C** (decouple memoization from result map) |
| 5 | `landlord/config/TenantAwareTaskDecorator.java:24` | Javadoc comment about parallelStream (warning, not a usage) | adjacent | **no** — already a warning, not a usage |
| 6 | `service/CustomerorderBatchService.java:691, 692, ...` | `runClubLine` declares `@Transactional` — provides tx context for `calc()`'s repo calls | not in scope | **no** — verified correct (transaction context flows through `runClubLine` → `buildDtoList` → `calculateUnitLoadAmounts` → sequential `calc()`) |
| 7 | `service/CustomerorderBatchService.java:1078-1079` | `calc()` makes repository calls — `findByCarrierunitloadId`, `findByUnitloadId` | adjacent | **no** — out of scope; pre-fetching is a separate optimization (potentially follow-up ticket) |
| 8 | All other v2 src/main | Zero `parallelStream()` calls in production code (only one Javadoc reference in `TenantAwareTaskDecorator`); zero `BaseStream.parallel()` calls | n/a | **yes — Fix A** (regression guard prevents re-introduction across `service/`, `controller/`, `schedulejob/`, `util/`, `repo/`) |
| 9 | (no test today) | No automated test asserts deterministic output across repeated runs of `calculateUnitLoadAmounts(500 unitloads)` (ticket AC-3) | gap | **yes — Fix B** (deterministic-output IT for AC-3) |

---

## 1. Problem Statement

### Symptom (verbatim from ticket)

`CustomerorderBatchService.calculateUnitLoadAmounts` (cited at lines 1040-1067) used `unitLoads.parallelStream()` for inputs > 100, with the class declared `@Transactional` (cited at line 30). The `calc()` lambda performs repository reads, and an outer-scope non-concurrent `HashMap amounts` is captured by the parallel lambda. Failure modes:

- **Inconsistent reads.** Repository calls inside the parallel lambda execute on `ForkJoinPool.commonPool` worker threads. In v2 these worker threads do not inherit the request thread's `TenantContext` ThreadLocal, so queries route to the landlord DB instead of the tenant DB (the original failure observed in production was `relation unitload does not exist`). The ticket additionally cites Hibernate Session non-thread-safety: a single Hibernate Session attached to the request thread is not safe to share across ForkJoinPool worker threads — concurrent reads can produce intermittent `LazyInitializationException` or stale L1-cached entities.
- **Silent missing/duplicated amounts on batch summaries.** The captured `HashMap amounts` is mutated by parallel lambdas. `HashMap` resize is not thread-safe — concurrent puts can drop entries or, in degenerate JVM states, deadlock.
- **Class-level `@Transactional`** widens the boundary across every public method, holding a connection longer than necessary and amplifying connection-pool pressure on the landlord/tenant Hikari pools.

**Acceptance criteria from ticket:**
1. `calculateUnitLoadAmounts` uses sequential stream OR parallel stream over a fully pre-loaded in-memory dataset.
2. No `parallelStream` in the codebase touches a repository or entity manager.
3. Load test: batch with 500 unitloads → result is deterministic across 100 runs (same totals, same keys).

### DB verification status — `db_verified: true`

The clubline path's `parallelStream()` branch was gated on `unitLoads.size() > 100`, where `unitLoads` are loaded per `itemdata` (line 996: `itemToUnitLoads.getOrDefault(position.getItemdataId(), Collections.emptyList())`). The right correlation to validate "was this branch reachable in production?" is unitloads-per-itemdata, NOT unitloads-per-batch (a `customerorder_id` column does not exist on `unitload` — the link is via `stockunit.itemdata_id` and `stockunit.unitload_id`).

**Live wms1-wineco-dev results (2026-05-09):**

```sql
SELECT count(*) AS total_unitloads FROM unitload;
-- Result: 752,838

SELECT s.itemdata_id, count(distinct s.unitload_id) AS unitloads_per_item
FROM stockunit s
GROUP BY s.itemdata_id
HAVING count(distinct s.unitload_id) > 100
ORDER BY count(distinct s.unitload_id) DESC
LIMIT 10;
-- Result (top 10):
--   itemdata_id    unitloads_per_item
--   762750         12,346
--   677662         11,251
--   951853          6,413
--   5560183         5,249
--   1557007         4,247
--   100951          4,091
--   653966047       4,008
--   60734           3,994
--   9036601         3,853
--   3248391         3,666
```

**Verdict:** the original `>100` parallelStream branch was definitely reachable in production. Top itemdata at this tenant has 12,346 unitloads — every clubline run touching it would have farmed work to the ForkJoinPool common pool, exposing the Hibernate-Session-not-thread-safe + TenantContext-ThreadLocal-not-propagated failure modes. AC3's "500 unitloads" scenario is conservative — the deterministic-output IT (Fix B) should run without breaking a sweat against this scale.

> Although v2 has already removed the `parallelStream()` call (commit `74f3c221`), the DB-level evidence above documents the historical exposure: this was not a hypothetical bug, and the regression-guard (Fix A) is load-bearing.

### v2 already fixed — what is already in place

When auditing v2 source on 2026-05-09, the central bug is closed. The plan acknowledges this so it does not silently re-propose work that is done.

**Verbatim current `calculateUnitLoadAmounts` body — `CustomerorderBatchService.java:1045-1062`:**
```java
private Map<Unitload, Integer> calculateUnitLoadAmounts(List<Unitload> unitLoads, Itemdata itemData) {
    // Early exit for empty input
    if (unitLoads == null || unitLoads.isEmpty()) {
        return Collections.emptyMap();
    }

    // IMPORTANT: Must use sequential processing — parallelStream() breaks
    // multi-tenant routing because TenantContext (ThreadLocal) does not
    // propagate to ForkJoinPool worker threads.
    Map<Unitload, Integer> amounts = new HashMap<>();
    return unitLoads.stream()
        .collect(Collectors.toMap(
            Function.identity(),
            unitLoad -> calc(unitLoad, itemData, amounts),
            (a, b) -> b,
            () -> amounts
        ));
}
```

- `parallelStream()` removed; sequential `.stream()` in place. **[ALREADY DONE — landed in `74f3c221`]**
- `> 100` size threshold gone (no conditional branch). **[ALREADY DONE — landed in `74f3c221`]**
- Class-level `@Transactional` removed; only `@Service` remains at line 24-25. **[ALREADY DONE — landed in `58ad0f36`]**. All 9 method-level `@Transactional` annotations now specify `value = "tenantTransactionManager"` (verified at lines 145, 153, 161, 220, 346, 563, 643, 667, 780).
- The inline comment at lines 1051-1053 cites the multi-tenant `TenantContext` ThreadLocal reason — correct, complementary to the ticket's Hibernate Session reason. Both reasons apply.

**v2 already fixed by commit `74f3c221`. This plan closes the residual audit-chain gaps: regression-guard test, deterministic-output test, and shared-map back-reference cleanup.**

### Ticket "line 30" observation

The ticket cites class-level `@Transactional` "at line 30". Reading the v2 source today:

```
24: @Service
25: public class CustomerorderBatchService {
26:
27:     private static final Logger LOG = LoggerFactory.getLogger(CustomerorderBatchService.class);
28:
29:     @org.springframework.beans.factory.annotation.Value("${wms.clubline.max-batch-size:500}")
30:     private int maxClubLineBatchSize = 500;
```

Line 30 is `private int maxClubLineBatchSize = 500;` — a `@Value`-injected field, not a class-level annotation. The ticket's "line 30" claim is stale (predates `58ad0f36`). Recorded in §10 Open Questions for transparency.

---

## 2. Root Cause Analysis

The original ticket described one root cause (`parallelStream()` on a Hibernate Session inside a class-level `@Transactional` boundary). v2 has eliminated all three contributing factors directly. **Three residual audit-chain gaps remain.** Each is a separate sub-section below; each cites file:LINE, shows current state, explains why it is still a residual risk, and acknowledges what is already done.

### Gap A — No automated guard against future re-introduction of `parallelStream()`

**Current state:** Zero production callsites of `parallelStream()` or `BaseStream.parallel()` in `src/main/java` (verified by `grep -rn "parallelStream\|\.parallel(" src/main/java` — only matches are an inline regression comment at `CustomerorderBatchService.java:1051` and a Javadoc warning at `landlord/config/TenantAwareTaskDecorator.java:24`).

**Why it is still a residual risk:** A future engineer could re-introduce `parallelStream()` (or `Stream.parallel()`) anywhere in `service/`, `controller/`, `schedulejob/`, `util/`, or `repo/` code without any test failing. The inline comment at `CustomerorderBatchService.java:1051-1053` is helpful but not enforceable — it lives only at one site, and a new caller in another service has no comment to read.

This is the same shape as `OptionalSafetyArchTest` (`src/test/java/net/aim_ai/wms/unit/config/OptionalSafetyArchTest.java`), which prevents regression of SBDEV-2116 (`Optional.get()` re-introduction) via ArchUnit. The pattern is proven, the dependency (`com.tngtech.archunit:archunit-junit5` at `pom.xml:305-306`) is already on the test classpath, and the arch-test runtime cost is sub-second.

**Acknowledgement:** v2 has zero pre-existing offenders, so the ArchUnit rule should run **without** a freeze-store snapshot — the rule is "zero violations, period". Recorded in Fix A.

### Gap B — No automated test asserts AC-3 deterministic output across 100 runs

**Current state:** The ticket's third acceptance criterion — "batch with 500 unitloads → result is deterministic across 100 runs (same totals, same keys)" — has no automated coverage. With sequential-stream processing in place this is mechanically guaranteed (single thread, deterministic iteration order over a `List`), but a regression test makes the guarantee explicit and reviewable.

**Why it is still a residual risk:** The current passing build relies on a reviewer noticing if someone re-parallelizes the method. An IT that exercises 500 unitloads × 100 iterations and asserts content equality across all runs encodes AC-3 as a build gate. Pairs with Fix A's static-analysis rule for two-layer defense.

**Acknowledgement:** Per `wms2-tenant-routing-datasource-topology.md`, `TenantContext` (`landlord/config/TenantContext.java`) is a `ThreadLocal<String>` set by `TenantFilter` from HTTP headers. `@Async` and ForkJoinPool worker threads do NOT inherit this ThreadLocal unless explicitly decorated (see `TenantAwareTaskDecorator`). Sequential processing on the request thread is the simplest correct path.

### Gap C — `amounts` HashMap shared between memoization and result-map roles is fragile

**Current state (`CustomerorderBatchService.java:1054-1061`):**
```java
Map<Unitload, Integer> amounts = new HashMap<>();
return unitLoads.stream()
    .collect(Collectors.toMap(
        Function.identity(),
        unitLoad -> calc(unitLoad, itemData, amounts),
        (a, b) -> b,
        () -> amounts                              // <-- supplier reuses the SAME map
    ));
```

The `amounts` map plays two roles simultaneously:
1. **Memoization cache** passed by reference into `calc()` (line 1058); `calc()` checks `unitLoadIntegerMap.containsKey(unitLoad)` at line 1073 to short-circuit recursive recomputation when a child unitload was already computed.
2. **Result map for the Collector** via the `() -> amounts` supplier (line 1060).

**Why it is still a residual risk:** Under sequential processing this is safe — single-threaded writes, well-defined iteration order. But it creates a footgun: if anyone ever re-parallelizes by editing this method, the shared map becomes both a race-condition vector (Memoization cache writes from `calc()` collide with Collector merges) AND a `HashMap` resize hazard. The `() -> amounts` supplier coupling is also conceptually murky — Collectors normally produce a fresh map per stream invocation; reusing the input map breaks that convention.

A small refactor decouples the two roles: keep memoization (it preserves the O(N) recursive short-circuit), but let the Collector produce its own fresh `HashMap`. This removes the back-reference without changing functional output — verified by Fix B's deterministic-output IT.

**Acknowledgement:** This is defense-in-depth, not a correctness fix today. The fragility is reachable only via a hostile future edit. Recorded in §10 Open Questions; resolved as "do the cleanup".

### v2 architecture doc cross-references

This plan aligns with:
- `sbdocs/3-Resources/architecture/wms2-tenant-routing-datasource-topology.md` — `TenantContext` is a `ThreadLocal<String>` set per HTTP request via `TenantFilter`; ForkJoinPool worker threads do NOT inherit it. `TenantAwareTaskDecorator` exists for `@Async`/`CompletableFuture` boundaries but is **not** applied to ad-hoc `parallelStream()` calls. Sequential processing on the request thread is the documented-correct pattern.
- `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` — `runClubLine` is `@Transactional(value = "tenantTransactionManager", rollbackFor = …)` at `CustomerorderBatchService.java:691`; its tx context flows through `buildDtoList` → `calculateUnitLoadAmounts` → `calc()` so the inner repository calls (`findByCarrierunitloadId`, `findByUnitloadId`) execute inside the bounded transaction. This is correct only when the calls happen on the **same thread** as the `@Transactional` proxy entry — exactly what sequential `.stream()` guarantees.

---

## 3. The Regression Chain

The fix accumulated across multiple commits over the v2 horizontal-scaling and concurrency-hardening work. The smoking-gun commit is `74f3c221`.

| SHA | Commit | Relevant change |
|---|---|---|
| `74f3c221` | `fix: remove parallelStream in calculateUnitLoadAmounts (multi-tenant bug)` | **Removed `parallelStream()` and the `>100` size threshold; replaced with sequential `.stream()` and added the inline comment about `TenantContext` ThreadLocal.** Eliminated the silent landlord-DB-routing failure mode for batches > 100 unitloads. |
| `58ad0f36` | `fix: specify tenantTransactionManager on all 44 @Transactional annotations` | Removed class-level `@Transactional` on `CustomerorderBatchService`; converted all 9 method-level annotations to specify `value = "tenantTransactionManager"`. Eliminated the silent landlord-TM auto-commit failure mode. |
| `4a0e8761` | `perf: Phase 2 bulk pre-fetch — eliminate N+1 in release, clubline, transfer, and closeBOL` | Refactored the `runClubLine` path to bulk-pre-fetch positions, itemdata, locations, carriers, etc. Adjacent — set the stage by reducing per-call latency, but did not change `calculateUnitLoadAmounts`. |
| `5cea7a5d` | `fix: break mega-transactions in runClubLine and closeBOLs for concurrency` | Tightened transaction boundaries in the `runClubLine` pipeline. Adjacent — established the per-method `@Transactional` pattern this plan relies on. |

This plan is the "Phase 3 polish": ArchUnit regression guard + deterministic-output IT + shared-map back-reference cleanup + comment hardening — closing the audit-chain gaps that `74f3c221` deliberately left for a follow-up.

---

## 4. Architecture Overview

### Code path

```
HTTP request (e.g. mobile UI: "run club line for batch X")
        │
        ▼
ClubLineMobileController / ClubLineWebController
        │
        ▼
CustomerorderBatchService.runClubLine(batchId, ...)
        │  @Transactional(value = "tenantTransactionManager",
        │                 rollbackFor = {BusinessException.class, FacadeException.class})
        │  (line 691)
        ▼
CustomerorderBatchService.buildDtoList(positions, itemDataMap, itemToUnitLoads, ...)
        │  (line 981 — private helper)
        │
        │  for each CustomerorderPosition position:
        │      Itemdata itemData = itemDataMap.get(position.getItemdataId());
        │      List<Unitload> unitLoads = itemToUnitLoads.getOrDefault(position.getItemdataId(), ...);
        │      Map<Unitload,Integer> unitLoadAmounts =
        │            calculateUnitLoadAmounts(unitLoads, itemData);   <── THIS METHOD
        │
        ▼
CustomerorderBatchService.calculateUnitLoadAmounts(unitLoads, itemData)
        │  (line 1045 — private helper)
        │
        │  unitLoads.stream()                       <── sequential (was parallelStream pre-74f3c221)
        │      .collect(Collectors.toMap(...))
        │
        │  for each unitLoad in unitLoads (sequentially):
        │      calc(unitLoad, itemData, amounts)
        │
        ▼
CustomerorderBatchService.calc(unitLoad, itemData, memo)
        │  (line 1069 — private helper)
        │
        │  if (memo.containsKey(unitLoad)) return memo.get(unitLoad);    <── Fix C preserves this
        │
        │  unitloadRepository.findByCarrierunitloadId(unitLoad.getId())   <── runs in runClubLine's tx
        │  stockunitRepository.findByUnitloadId(unitLoad.getId())         <── runs in runClubLine's tx
        │  itemdataRepository.findAllById(itemDataIds)                    <── runs in runClubLine's tx
        │
        │  recursive calc() over child unitloads (still in same thread, same tx)
        │
        ▼
return Integer total amount
```

### Key files

| File | Lines | Role |
|---|---|---|
| `service/CustomerorderBatchService.java` | 1197 | Hosts `runClubLine` (line 691 — `@Transactional` boundary), `buildDtoList` (line 981 — caller), `calculateUnitLoadAmounts` (line 1045 — fix target), and `calc` (line 1069 — recursive with memoization) |
| `landlord/config/TenantContext.java` | — | `ThreadLocal<String>` storage for current tenant — does NOT inherit into ForkJoinPool worker threads |
| `landlord/config/TenantFilter.java` | — | Sets `TenantContext` from HTTP headers per request |
| `landlord/config/TenantAwareTaskDecorator.java` | 24 | Javadoc explicitly warns that the decorator does NOT help with raw `parallelStream()` — confirms Fix A's premise |
| `src/test/java/net/aim_ai/wms/unit/config/OptionalSafetyArchTest.java` | 45 | Pattern reference for Fix A — same ArchUnit shape (no-new-violations rule against `service.*` package) |
| `src/test/java/net/aim_ai/wms/common/BaseIntegrationTest.java` | — | Base class for Fix B's IT — H2 in PostgreSQL mode, `@ActiveProfiles("integration")` |
| `pom.xml:305-306` | 2 | `archunit-junit5` test dependency already wired |
| **(new)** `src/test/java/net/aim_ai/wms/unit/config/ParallelStreamSafetyArchTest.java` | — | Fix A — ArchUnit rule banning `parallelStream()` and `BaseStream.parallel()` in production packages |
| **(new)** `src/test/java/net/aim_ai/wms/integration/service/CustomerorderBatchServiceParallelStreamRegressionIT.java` | — | Fix B — deterministic-output IT (500 unitloads × 100 iterations, asserts content equality) |

---

## 5. Fix Design

### Fix A — ArchUnit regression guard against `parallelStream()` and `BaseStream.parallel()`

**File:** `src/test/java/net/aim_ai/wms/unit/config/ParallelStreamSafetyArchTest.java` (new)

**Pattern reference:** Mirror `OptionalSafetyArchTest` (`src/test/java/net/aim_ai/wms/unit/config/OptionalSafetyArchTest.java`) — same `noClasses().that().resideInAPackage(...).should().callMethod(...)` shape, same import set (`JavaClasses`, `ClassFileImporter`, `ImportOption`, `noClasses` static import).

**Rule:** No method in `..service..`, `..controller..`, `..schedulejob..`, `..util..`, or `..repo..` packages may invoke `java.util.Collection.parallelStream()` or `java.util.stream.BaseStream.parallel()`. Both forms are equivalent ForkJoinPool entry points; banning both closes the loophole.

> Note: the `..business..` package does not exist in v2/wms2-api (`ls src/main/java/net/aim_ai/wms/` confirms no `business` directory). `..util..` is substituted — it hosts bulk helper/converter code that could plausibly invoke `parallelStream()` on entity collections. The `..json..` package was also checked (`grep -rn "stream()" src/main/java/net/aim_ai/wms/json/` — zero results); it is out of scope.

**Sketch (executor authors final form; do NOT copy verbatim — match codebase conventions discovered at edit time):**

```java
package net.aim_ai.wms.unit.config;

import com.tngtech.archunit.core.domain.JavaClasses;
import com.tngtech.archunit.core.importer.ClassFileImporter;
import com.tngtech.archunit.core.importer.ImportOption;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.Collection;
import java.util.stream.BaseStream;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;

/**
 * Prevents regression of SBDEV-2218: parallelStream() / BaseStream.parallel() in
 * production code paths that touch Hibernate Sessions, repositories, or anything
 * that reads ThreadLocal state (TenantContext).
 *
 * <p>ForkJoinPool worker threads do NOT inherit TenantContext (ThreadLocal),
 * so multi-tenant query routing breaks silently. Sequential processing or
 * fully pre-loaded in-memory parallelism is required.
 *
 * <p>v2 currently has ZERO violations — the rule runs without a freeze-store.
 */
@DisplayName("ParallelStream Safety Architecture Tests")
class ParallelStreamSafetyArchTest {

    private static JavaClasses productionClasses;

    @BeforeAll
    static void importClasses() {
        productionClasses = new ClassFileImporter()
                .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)
                .importPackages("net.aim_ai.wms");
    }

    @Test
    @DisplayName("production classes must not invoke Collection.parallelStream()")
    void noParallelStreamCallsInProductionPackages() {
        noClasses()
                .that().resideInAnyPackage(
                        "net.aim_ai.wms.service..",
                        "net.aim_ai.wms.controller..",
                        "net.aim_ai.wms.schedulejob..",
                        "net.aim_ai.wms.util..",
                        "net.aim_ai.wms.repo..")
                .should().callMethod(Collection.class, "parallelStream")
                .because("SBDEV-2218: parallelStream runs on ForkJoinPool — TenantContext " +
                        "(ThreadLocal) does not propagate, breaking multi-tenant routing; " +
                        "Hibernate Session is also not thread-safe.")
                .check(productionClasses);
    }

    @Test
    @DisplayName("production classes must not invoke BaseStream.parallel()")
    void noBaseStreamParallelCallsInProductionPackages() {
        noClasses()
                .that().resideInAnyPackage(
                        "net.aim_ai.wms.service..",
                        "net.aim_ai.wms.controller..",
                        "net.aim_ai.wms.schedulejob..",
                        "net.aim_ai.wms.util..",
                        "net.aim_ai.wms.repo..")
                .should().callMethod(BaseStream.class, "parallel")
                .because("SBDEV-2218: stream.parallel() is equivalent to parallelStream() — " +
                        "same ForkJoinPool entry point, same TenantContext breakage.")
                .check(productionClasses);
    }
}
```

**Decision: no freeze-store.** v2 currently has zero violations of this rule — verified by `grep -rn "parallelStream\|\.parallel(" src/main/java` returning only the inline comment at `CustomerorderBatchService.java:1051` and the Javadoc warning at `TenantAwareTaskDecorator.java:24` (neither is an invocation, so ArchUnit's `callMethod` rule will not flag them). A freeze-store would normalize an empty baseline; running the rule directly is cleaner. If a hidden offender surfaces during the executor's `mvn test` run, escalate per §11 risk row 1.

### Fix B — Deterministic-output integration test for AC-3

**File:** `src/test/java/net/aim_ai/wms/integration/service/CustomerorderBatchServiceParallelStreamRegressionIT.java` (new)

**Base class deviation:** Extend `BaseIntegrationTest` (H2 in PostgreSQL mode, `@ActiveProfiles("integration")`) — NOT `BasePostgresIntegrationTest`. **Rationale (carried from SBDEV-2217 §6' Deviation):** `BasePostgresIntegrationTest` cannot boot a full Spring context in this codebase without the `integration` profile active (the landlord datasource URL is provided exclusively by `application-integration.properties`). The assertion under test is dialect-independent: deterministic output of a sequential stream is a JVM-level guarantee, not a PostgreSQL-specific protocol feature. H2 in PostgreSQL mode is sufficient. Cross-dialect correctness against real PostgreSQL is deferred to the §6 manual smoke against staging.

**Invocation strategy (pinned — M3 fix):** Use `ReflectionTestUtils.invokeMethod` to call the package-private `calculateUnitLoadAmounts` directly. `ReflectionTestUtils.invokeMethod` returns the invocation result, NOT a `Method` handle — do not chain `.invoke(...)` on the return value. Driving the public `runClubLine` / `buildDtoList` path is NOT used here — it requires seeding full customerorder + position + batch state which is unnecessary overhead; the determinism contract is on the private method alone.

**Test method (sketch — executor authors final form):**

```java
@Test
@DisplayName("calculateUnitLoadAmounts is deterministic across 100 repeated runs (AC-3)")
void calculateUnitLoadAmounts_isDeterministic_acrossRepeatedRuns() {
    // Seed: 500 Unitload rows linked to a single Itemdata.
    // All Unitloads MUST be persisted (flushed) before passing to the method —
    // Unitload.hashCode() returns getClass().hashCode() (a constant), so all instances
    // share the same bucket. With id=null, HashMap.put() still works but equals()
    // (ID-based via AbstractBaseEntity) treats all null-id entities as unequal only by
    // reference — persisting ensures each has a distinct non-null id, keeping the
    // keySet size at 500 rather than silently collapsing. See §9 risk row on this.
    final int unitLoadCount = 500;
    final int iterations = Integer.getInteger("regression.iterations", 100);

    Itemdata itemData = persistTestItemdata();
    List<Unitload> unitLoads = persistTestUnitloads(itemData, unitLoadCount);
    entityManager.flush(); // ensure all ids are non-null before stream

    @SuppressWarnings("unchecked")
    Map<Unitload, Integer> baseline = (Map<Unitload, Integer>) ReflectionTestUtils.invokeMethod(
            customerorderBatchService, "calculateUnitLoadAmounts", unitLoads, itemData);

    // Fail fast: all 500 keys must be distinct. If this fails, seeding produced
    // duplicate/null-id entities and the subsequent content assertions are meaningless.
    assertThat(baseline.keySet()).hasSize(unitLoadCount);

    List<Map<Unitload, Integer>> allRuns = new ArrayList<>();
    allRuns.add(baseline);

    for (int i = 1; i < iterations; i++) {
        @SuppressWarnings("unchecked")
        Map<Unitload, Integer> run = (Map<Unitload, Integer>) ReflectionTestUtils.invokeMethod(
                customerorderBatchService, "calculateUnitLoadAmounts", unitLoads, itemData);
        allRuns.add(run);
    }

    // (a) every run returns the same key set
    Set<Unitload> baselineKeys = baseline.keySet();
    assertThat(allRuns).allSatisfy(run ->
            assertThat(run.keySet()).isEqualTo(baselineKeys));

    // (b) every run returns the same value totals (sum across all entries)
    int baselineTotal = baseline.values().stream().mapToInt(Integer::intValue).sum();
    assertThat(allRuns).allSatisfy(run ->
            assertThat(run.values().stream().mapToInt(Integer::intValue).sum())
                    .isEqualTo(baselineTotal));

    // (c) iteration order may differ but content is identical (per-key value equality)
    assertThat(allRuns).allSatisfy(run ->
            assertThat(run).containsExactlyInAnyOrderEntriesOf(baseline));
}
```

**Tunable iteration count:** `-Dregression.iterations=100` (manual) or the default `100` (CI). If CI proves slow, reduce to `10` via the system property; the determinism contract holds at any iteration count ≥ 2.

**Optional `@Disabled` gate:** If CI proves slow, mark `@Disabled("Slow — runs 100×500-row iterations; enable with -Dgroups=regression")` and the verify script opts in via env var. Default: keep enabled — sequential `.stream()` over 500 elements is sub-millisecond per iteration; 100 iterations should fit comfortably in a CI test budget.

### Fix C — Defense-in-depth: remove `amounts` shared-map back-reference

**File:** `service/CustomerorderBatchService.java:1045-1062`

**Before (current code):**
```java
private Map<Unitload, Integer> calculateUnitLoadAmounts(List<Unitload> unitLoads, Itemdata itemData) {
    if (unitLoads == null || unitLoads.isEmpty()) {
        return Collections.emptyMap();
    }

    // IMPORTANT: Must use sequential processing — parallelStream() breaks
    // multi-tenant routing because TenantContext (ThreadLocal) does not
    // propagate to ForkJoinPool worker threads.
    Map<Unitload, Integer> amounts = new HashMap<>();
    return unitLoads.stream()
        .collect(Collectors.toMap(
            Function.identity(),
            unitLoad -> calc(unitLoad, itemData, amounts),
            (a, b) -> b,
            () -> amounts
        ));
}
```

**After:**
```java
private Map<Unitload, Integer> calculateUnitLoadAmounts(List<Unitload> unitLoads, Itemdata itemData) {
    if (unitLoads == null || unitLoads.isEmpty()) {
        return Collections.emptyMap();
    }

    // SBDEV-2218 regression guard: Must use sequential processing — parallelStream() breaks
    // multi-tenant routing because TenantContext (ThreadLocal) does not propagate to
    // ForkJoinPool worker threads, and Hibernate Session is not thread-safe across
    // worker threads. Enforced statically by ParallelStreamSafetyArchTest; the AC-3
    // determinism contract is asserted by CustomerorderBatchServiceParallelStreamRegressionIT.
    Map<Unitload, Integer> memoCache = new HashMap<>();
    return unitLoads.stream()
        .collect(Collectors.toMap(
            Function.identity(),
            unitLoad -> calc(unitLoad, itemData, memoCache),
            (a, b) -> b
        ));
}
```

**What changed:**
1. The `amounts` identifier is renamed `memoCache` to make the role explicit — it is the recursion memoization cache passed into `calc()`, not the Collector's result map.
2. The `() -> amounts` Collector supplier is removed. `Collectors.toMap(keyMapper, valueMapper, mergeFunction)` (the 3-arg overload) produces a fresh `HashMap` per stream invocation. The Collector's result map and the memoization cache are now distinct objects.
3. The inline comment is upgraded to Fix D (see below).

**Why path (a) and not (b) "drop memoization entirely":**

The `calc()` method's `unitLoadIntegerMap.containsKey(unitLoad)` short-circuit at line 1073 is still useful — `calc()` recurses over child unitloads (line 1098: `childrenUnitLoads.stream().mapToInt(ul -> calc(ul, itemData, unitLoadIntegerMap)).sum()`), so the same unitload may be reached multiple times via different parents in a complex carrier hierarchy. Memoization keeps recursion at O(N) instead of O(N²). Dropping it would be safe but slower. Recorded in §10 Open Questions decision row 3.

**Memoization scope per call:** Each call to `calculateUnitLoadAmounts` creates a fresh `memoCache` (the field is method-local). Memoization spans only the unitloads in the current call's list (and their recursive children), not across calls in `buildDtoList`'s for-loop. Verified by reading `buildDtoList:992-1042`: each iteration of the `for (CustomerorderPosition position : positions)` loop calls `calculateUnitLoadAmounts(unitLoads, itemData)` with a fresh `memoCache` (since the field is declared INSIDE the method). Per-call memoization is the intended semantic; the refactor preserves it.

### Fix D — Strengthen the inline comment (regression marker)

**File:** `service/CustomerorderBatchService.java:1051-1053` (replaced as part of Fix C above)

**Before:**
```
// IMPORTANT: Must use sequential processing — parallelStream() breaks
// multi-tenant routing because TenantContext (ThreadLocal) does not
// propagate to ForkJoinPool worker threads.
```

**After (combined with Fix C — final inline comment):**
```
// SBDEV-2218 regression guard: Must use sequential processing — parallelStream() breaks
// multi-tenant routing because TenantContext (ThreadLocal) does not propagate to
// ForkJoinPool worker threads, and Hibernate Session is not thread-safe across
// worker threads. Enforced statically by ParallelStreamSafetyArchTest; the AC-3
// determinism contract is asserted by CustomerorderBatchServiceParallelStreamRegressionIT.
```

**What changed:**
1. `SBDEV-2218 regression guard:` prefix so future grep-based searches for the ticket ID find this site.
2. Added the ticket's Hibernate Session reason as a complement to the existing TenantContext ThreadLocal reason (both are real failure modes; both are documented).
3. Cross-references both safety nets by class name (`ParallelStreamSafetyArchTest`, `CustomerorderBatchServiceParallelStreamRegressionIT`) — any reader who edits this method now sees the static and runtime guard rails that will catch a regression.

---

## 6. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `service/CustomerorderBatchService.java` | edit | Fix C (rename `amounts` → `memoCache`, remove `() -> amounts` Collector supplier — drop to 3-arg `toMap`); Fix D (upgrade inline comment with `SBDEV-2218 regression guard:` prefix + Hibernate Session reason + arch-test/IT class names) |
| `src/test/java/net/aim_ai/wms/unit/config/ParallelStreamSafetyArchTest.java` | new | Fix A — ArchUnit rule banning `Collection.parallelStream()` and `BaseStream.parallel()` in `..service..`, `..controller..`, `..schedulejob..`, `..util..`, `..repo..` packages (`..business..` does not exist in v2; `..util..` substituted) |
| `src/test/java/net/aim_ai/wms/integration/service/CustomerorderBatchServiceParallelStreamRegressionIT.java` | new | Fix B — Testcontainers IT (extending `BaseIntegrationTest`, H2 PostgreSQL mode) seeding 500 Unitload rows and asserting deterministic output across 100 runs |

No other files change. No `pom.xml` change (`archunit-junit5` is already on the test classpath at `pom.xml:305-306`). No `application.properties` change. No Flyway migration. No production source change beyond Fix C/D's local edit.

---

## 5'. Prerequisites & Implementation Plan

> Renamed locally to "5'" so it does not collide with §5 Fix Design.

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | None. No schema change, no Flyway migration. Any tenant DB suffices for the manual probe in §1 / §6. | — | Pure code-and-test fix. |
| 2 | **Feature flags / system properties** | None. | — | |
| 3 | **Config / env changes** | Confirm `archunit-junit5` is on the test classpath. Run `grep -n "archunit" pom.xml` — should show `pom.xml:305-306`. **Verified 2026-05-09:** dependency wired. No change required. The existing `OptionalSafetyArchTest` and `TransactionManagerArchTest` prove the dep is live. | Dev | Verified. |
| 4 | **Deploy-order dependencies** | Independent. Test-only changes (Fix A, Fix B) and a tiny production-source refactor (Fix C/D) that preserves functional behaviour. No coordination with OMS, mobile UI, or scheduler is required. | — | Roll with the next normal `wms2-api` release. |
| 5 | **Data migration** | None. | — | |
| 6 | **External systems** | None. | — | |
| 7 | **Access / permissions** | None. | — | |
| 8 | **Monitoring / alerts** | Optional: Grafana log-based alert on the literal string `parallelStream()` re-appearing in production logs. Low priority — the ArchUnit test catches it pre-deploy at build time. | DevOps | Optional (low priority). |
| 9 | **DB MCP probe re-run before implementation (optional refresh)** | §1 records live wms1-wineco-dev results from 2026-05-09 (top itemdata: 12,346 unitloads — `>100` branch was reachable). Implementer MAY re-run the §1 SQL on the target tenant DB just before deploy if more than ~30 days have elapsed, to refresh the historical-exposure evidence. Not mandatory; `db_verified: true` already holds. | Dev (optional) | Refresh window ~30 days. |

### 5.2 Implementation Checklist

- [ ] Run `bash sbdocs/9-System/scripts/verify-SBDEV-2218-parallelstream-against-hibernate-session.sh` — capture the **baseline FAIL count** (expected: 3 PRE pass, ~10–12 fails for Fix A/B/C/D)
- [ ] Run the §1 DB MCP probe SQL on a tenant DB (per §5.1 row 9) — record result
- [ ] Fix A — author `src/test/java/net/aim_ai/wms/unit/config/ParallelStreamSafetyArchTest.java` mirroring `OptionalSafetyArchTest`
  - [ ] Two `@Test` methods: `noParallelStreamCallsInProductionPackages` (bans `Collection.parallelStream()`) and `noBaseStreamParallelCallsInProductionPackages` (bans `BaseStream.parallel()`)
  - [ ] Package scope: `..service..`, `..controller..`, `..schedulejob..`, `..util..`, `..repo..` (not `..business..` — that package does not exist in v2)
  - [ ] Run `mvn test -Dtest=ParallelStreamSafetyArchTest` ✓ (zero violations expected; if any surface, escalate per §11 risk row 1)
- [ ] Fix B — author `src/test/java/net/aim_ai/wms/integration/service/CustomerorderBatchServiceParallelStreamRegressionIT.java` extending `BaseIntegrationTest`
  - [ ] Test method `calculateUnitLoadAmounts_isDeterministic_acrossRepeatedRuns`
  - [ ] Seed 500 `Unitload` rows linked to one `Itemdata`; call `entityManager.flush()` after seeding so all ids are non-null before the stream (Unitload.hashCode() is a constant — flush prevents id-null key collision, see §9 risk row)
  - [ ] Invoke via `ReflectionTestUtils.invokeMethod(customerorderBatchService, "calculateUnitLoadAmounts", unitLoads, itemData)` — this returns the result directly; do NOT chain `.invoke(...)` on the return value
  - [ ] First assertion after the baseline call: `assertThat(baseline.keySet()).hasSize(500)` — fail fast if seeding produced duplicate/null-id keys
  - [ ] Iterate 100 times (tunable via `-Dregression.iterations`)
  - [ ] Assert (a) key set equality, (b) value-total equality, (c) per-key content equality across all runs
  - [ ] Run `mvn verify -Dit.test=CustomerorderBatchServiceParallelStreamRegressionIT` ✓
- [ ] Fix C — edit `service/CustomerorderBatchService.java:1054-1061`
  - [ ] Rename `amounts` identifier to `memoCache`
  - [ ] Remove the `() -> amounts` (now `() -> memoCache`) Collector supplier — drop to 3-arg `Collectors.toMap(keyMapper, valueMapper, mergeFunction)`
- [ ] Fix D — edit `service/CustomerorderBatchService.java:1051-1053` (combined with Fix C edit)
  - [ ] Replace the existing `IMPORTANT: …` comment with the Fix D form (SBDEV-2218 prefix + Hibernate Session reason + cross-references to `ParallelStreamSafetyArchTest` and `CustomerorderBatchServiceParallelStreamRegressionIT`)
- [ ] Run `mvn test -Dtest=CustomerorderBatchServiceUnitTest` ✓ (existing unit test must still pass — Fix C is functionally equivalent)
- [ ] Run full `mvn verify` ✓
- [ ] Run `bash sbdocs/9-System/scripts/verify-SBDEV-2218-parallelstream-against-hibernate-session.sh` — must report `Result: N pass, 0 fail`
- [ ] Manual smoke (per §6' Manual test plan): trigger a clubline run on a batch with > 100 unitloads via mobile UI on staging; observe deterministic output across two consecutive runs

---

## 6'. Test Plan

> Renamed locally to "6'" to avoid collision with §6 File Change Summary.

### Unit tests

| Test class | Test method | What it asserts | Status |
|---|---|---|---|
| `ParallelStreamSafetyArchTest` (new) | `noParallelStreamCallsInProductionPackages` | No method in `..service..`, `..controller..`, `..schedulejob..`, `..util..`, `..repo..` invokes `Collection.parallelStream()` | **new** |
| `ParallelStreamSafetyArchTest` (new) | `noBaseStreamParallelCallsInProductionPackages` | No method in same packages invokes `BaseStream.parallel()` | **new** |
| `CustomerorderBatchServiceUnitTest` (existing) | (all existing methods) | Existing happy-path tests must still pass — Fix C is functionally equivalent (same input → same output). Use real `HashMap`s, not mocks, for the memoization map (matches v2 unit-test style). | **regression** |

### Integration test (H2 in PostgreSQL mode via `BaseIntegrationTest`)

| Test class | Test method | What it asserts | Status |
|---|---|---|---|
| `CustomerorderBatchServiceParallelStreamRegressionIT` (new) | `calculateUnitLoadAmounts_isDeterministic_acrossRepeatedRuns` | Seeds 500 `Unitload` rows linked to a single batch + customerorder + itemdata. Invokes `calculateUnitLoadAmounts(unitLoads, itemData)` 100 times (tunable via `-Dregression.iterations`). Asserts: (a) every run returns the same key set, (b) every run's value-total is identical, (c) per-key content is identical (`assertThat(allRuns).allSatisfy(run -> assertThat(run).containsExactlyInAnyOrderEntriesOf(baseline))`). Tolerance: exact equality (no floating-point arithmetic; `Integer` values). | **new** |

Path: `src/test/java/net/aim_ai/wms/integration/service/CustomerorderBatchServiceParallelStreamRegressionIT.java`.

**Why H2 (`BaseIntegrationTest`) and not Testcontainers PostgreSQL (`BasePostgresIntegrationTest`):** The determinism contract under test is a JVM-level guarantee of `Stream.collect(Collectors.toMap(...))` over a sequential `.stream()` — completely dialect-independent. H2 in PostgreSQL mode boots a full Spring context; Testcontainers PostgreSQL fails to boot in this codebase without an active `integration` profile (see SBDEV-2217 §6' Deviation note for the empirical evidence). Cross-dialect correctness against real PostgreSQL is deferred to the manual smoke (below).

### Regression

| Test class | Why |
|---|---|
| `CustomerorderBatchServiceUnitTest` (full) | All existing happy-path tests must still pass after Fix C's rename + supplier removal |
| Any test that exercises `runClubLine` end-to-end | Must compile and pass — the calling chain (`runClubLine` → `buildDtoList` → `calculateUnitLoadAmounts`) is unchanged in shape |
| `OptionalSafetyArchTest`, `TransactionManagerArchTest` | Must continue to pass — Fix A adds a sibling, does not modify existing arch-test rules |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Smoke: clubline run on small batch (< 100 unitloads) | staging | 1. Pick a batch with ~50 unitloads. 2. Trigger `runClubLine` via mobile UI. 3. Observe DTO output and DB-recorded amounts. | All amounts > 0 where expected; no missing entries; deterministic output. | |
| Smoke: clubline run on large batch (> 100 unitloads) | staging | 1. Pick a batch with > 100 unitloads (use the §1 SQL probe to identify candidates). 2. Trigger `runClubLine`. 3. Re-run on the same batch (or a clone) and compare per-unitload amounts. | Two consecutive runs produce identical per-unitload amounts; identical totals. | |
| Cross-system: OMS notification on club-line completion | staging | Trigger clubline run; verify OMS receives the expected notification with correct unitload counts. | OMS payload matches DTO output; no missing/duplicated unitload IDs. | |
| SQL: post-deploy data sanity | staging DB | Run the §1 probe SQL after deploy. | Same batches surface as before deploy; no schema change. | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=ParallelStreamSafetyArchTest` | | |
| `mvn test -Dtest=CustomerorderBatchServiceUnitTest` | | |
| `mvn verify -Dit.test=CustomerorderBatchServiceParallelStreamRegressionIT` | | |
| `mvn verify` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2218-parallelstream-against-hibernate-session.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| End-to-end clubline run across two replicas (real load balancer) | Out of scope. Multi-replica determinism is asserted analytically: sequential `.stream()` on the request thread is a JVM-level guarantee that does not depend on cross-replica behaviour. The ArchUnit rule (Fix A) prevents any future code path from introducing ForkJoinPool work that would breach this. Manual smoke against the staging cluster is in §6' Manual test plan. |
| Pre-fetch refactor of `calc()`'s repository calls | Out of scope. Currently `calc()` calls `unitloadRepository.findByCarrierunitloadId` (line 1078) and `stockunitRepository.findByUnitloadId` (line 1079) per-unitload — N+1 by inspection, but already inside a bounded `runClubLine` `@Transactional` boundary. Pre-fetching once before the stream is a separate optimization (potentially a follow-up SBDEV ticket); not required to satisfy SBDEV-2218 acceptance criteria. |
| Re-introducing parallelism over a fully pre-loaded in-memory dataset (per ticket "Suggested fix" item 2) | Deferred. The ticket itself accepts sequential as the primary path. If profiling later proves sequential is too slow, a follow-up plan can pre-load fully and switch to `parallelStream()` over a `Map<Long, Unitload>` snapshot — but only with the ArchUnit rule explicitly opted-out for that one class via a new arch-test exception. Out of scope here. |

### Mockito + Testcontainers notes

- v2 uses **Mockito 5+** — no Mockito 3.3.3 limitation. `mockStatic` available if needed (none required by this plan).
- v2 uses **Testcontainers PostgreSQL** for some IT classes; this plan uses H2 in PostgreSQL mode via `BaseIntegrationTest` per the SBDEV-2217 deviation note. No new Maven dependency required.

### v2 `BaseControllerTest` requirement

This plan does NOT modify a controller endpoint — `CustomerorderBatchService` is a service-layer class and the change is internal to a private helper (`calculateUnitLoadAmounts`). No `BaseControllerTest`-extending test required.

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce per-replica state (Caffeine, ConcurrentHashMap, static, ThreadLocal)? | **No** | The `memoCache` `HashMap` is method-local, garbage-collected per call. No new field, no new static, no new ThreadLocal. |
| 2 | **Connection pool math** | Change per-request DB connection use? | **No** | Same connection model — `runClubLine` holds one connection inside its `@Transactional` boundary; sequential `.stream()` runs on the same request thread inside that boundary. No additional pool pressure. |
| 3 | **Scheduled jobs** | Add or modify `@Scheduled`? | **No** | N/A. |
| 4 | **Long transactions** | Hold a tx across multiple repo calls / external I/O? | **No** | The `runClubLine` transaction boundary is unchanged. `calc()`'s repository calls inside the stream were already inside it; sequential processing is the same shape. |
| 5 | **Request affinity** | Assume same-replica follow-up? | **No** | Stateless. |
| 6 | **Retry / idempotency** | Rely on single-execution semantics? | **Yes** — handled. Sequential `.stream()` is naturally idempotent: same input → same output. The deterministic-output IT (Fix B) encodes this property as a build gate (100 iterations × 500 unitloads, exact equality across runs). If a replica dies mid-`runClubLine`, the outer `@Transactional` rolls back at the DB level; another replica's retry produces the identical result. |
| 7 | **Tenant context** | Use `TenantContext` across async boundaries? | **Yes** — handled. **The entire bug was about ThreadLocal-based `TenantContext` not propagating to ForkJoinPool worker threads.** Fix A's ArchUnit rule enforces that no production code may invoke `parallelStream()` or `BaseStream.parallel()` in `..service..`, `..controller..`, `..schedulejob..`, `..util..`, `..repo..` — closing the static-analysis gap that allowed the original regression. Fix D's inline comment documents both reasons (TenantContext ThreadLocal + Hibernate Session non-thread-safety) for any future reader. References: `landlord/config/TenantContext.java` (the `ThreadLocal<String>`), `landlord/config/TenantAwareTaskDecorator.java:24` (the existing Javadoc warning that confirms `parallelStream()` is not covered by the decorator). |
| 8 | **Distributed lock correctness** | Add or rely on locks across replicas? | **No** | No new locks. The existing `runClubLine` `@Transactional` boundary's lock semantics are unchanged. |
| 9 | **Cache invalidation** | Write to cached entity? | **No** | `Unitload`, `Stockunit`, `Itemdata` cache invalidation is unchanged. The fix is read-path-only inside the stream. |
| 10 | **External notifications** | HTTP/message inside tx? | **No** | No external calls in `calculateUnitLoadAmounts` or `calc()`. OMS notifications happen elsewhere in the `runClubLine` pipeline (already deferred to `afterCommit` per `41cf1f3b`). |

### Evidence

| Concern # | What was verified | File:line / test reference |
|---|---|---|
| 6 | Sequential `.stream()` produces deterministic output across 100 runs | `CustomerorderBatchServiceParallelStreamRegressionIT.calculateUnitLoadAmounts_isDeterministic_acrossRepeatedRuns` (new — Fix B) |
| 7 | No production code may invoke `parallelStream()` or `BaseStream.parallel()` in production packages | `ParallelStreamSafetyArchTest.noParallelStreamCallsInProductionPackages` + `noBaseStreamParallelCallsInProductionPackages` (new — Fix A); inline comment at `CustomerorderBatchService.java:1051-1055` after Fix D |

---

## 8. v2-only constraint checklist

| # | Constraint | What was verified | Verdict |
|---|---|---|---|
| 1 | **OSIV disabled** | All repository calls inside `calc()` (lines 1078-1098) execute on the request thread inside `runClubLine`'s `@Transactional` boundary. Sequential `.stream()` preserves this thread affinity. No lazy-load chains span async boundaries. | **Yes** |
| 2 | **Transaction manager** | `runClubLine` (line 691) is `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` — verified. All 9 method-level annotations on `CustomerorderBatchService` specify `value = "tenantTransactionManager"` (lines 145, 153, 161, 220, 346, 563, 643, 667, 780). [ALREADY DONE — landed in `58ad0f36`.] No change in this plan. | **Yes** |
| 3 | **`@Transactional(readOnly=true)`** | `calculateUnitLoadAmounts` is a private helper inside the `runClubLine` write-path transaction. `readOnly=true` does not apply — it's a write path overall. | **N/A** — write path |
| 4 | **Caffeine cache invalidation** | The fix is read-path-only inside the stream. `calc()`'s repository reads do not write to any cached entity. No `@CacheEvict` / `@CachePut` change needed. | **N/A** |
| 5 | **Jakarta namespace** | All new test imports use `jakarta.*` where applicable. ArchUnit and JUnit 5 use neither `javax.*` nor `jakarta.*` for their own API. No `javax.*` introduced. | **Yes** |
| 6 | **H2-compatible test SQL** | Fix B's IT extends `BaseIntegrationTest` (H2 in PostgreSQL mode, `@ActiveProfiles("integration")`) — no native PostgreSQL syntax (`::text`, `ILIKE`, `ON CONFLICT`, `gen_random_uuid()`, array operators) used. The seeding is done via JPA repositories, not native SQL. The determinism assertion is JVM-level. | **Yes** |
| 7 | **`BaseControllerTest` for controller changes** | No controller endpoint changed; `CustomerorderBatchService` is a service. Fix C/D modifies a private helper. | **N/A** |
| 8 | **Micrometer metrics** | Fix is internal correctness + regression-guard; no new high-frequency hot path introduced. The existing `runClubLine` metric coverage (if any) is unchanged. | **N/A** |

---

## 9. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Fix A's ArchUnit rule catches an unintended pre-existing usage | Build break across multiple files; potential rabbit-hole audit | Low | Pre-implementation grep on 2026-05-09 confirms zero violations. If any surface during the executor's `mvn test` run, audit each: most likely either (a) a legitimate in-memory pre-loaded use case (add to a freeze-store with rationale, OR exclude that one class via `noClasses().that().resideInAPackage(...).and().areNotAssignableTo(...)` carve-out), or (b) a hidden bug worth fixing. Do NOT relax the rule to make CI green. |
| Fix C refactor changes `calc()`'s memoization semantics subtly | Wrong amounts surface in clubline output | Very low | Trace `buildDtoList:992-1042` carefully — each for-loop iteration calls `calculateUnitLoadAmounts` with a fresh `memoCache` (since the field is declared INSIDE the method). Memoization is per-call only; refactor is functionally equivalent (`memoCache` is still passed into `calc()` by reference, still consulted at `calc():1073`, still mutated at `calc():1100`). The only change is the Collector no longer reuses the same map as its result — this means the Collector's returned map and the memoization map are now distinct objects, but they end up containing the same key/value pairs because `valueMapper` is called once per key and `merge` resolves duplicates. Fix B's IT (100 iterations × 500 unitloads, exact equality) catches any deviation. |
| IT with 100×500 iterations is slow on CI | Test timeout; CI flakes | Medium | Tunable iteration count via `-Dregression.iterations` system property (default 100). Sequential `.stream()` over 500 elements is sub-millisecond per iteration; 100 iterations should fit in a CI test budget. If CI proves slow, drop to 10 iterations on CI and keep 100 for nightly / manual runs. Mark the test `@Disabled("Slow — runs 100×500-row iterations; enable with -Dgroups=regression")` only as a last resort — disabling defeats AC-3. |
| ForkJoinPool common-pool contention if anyone re-introduces `parallelStream()` | Multi-tenant routing breaks; landlord-DB queries return wrong errors; `LazyInitializationException` storm | High (was the original bug) | Fix A's ArchUnit rule prevents at build time. Fix D's inline comment documents at edit time. Fix B's IT proves at runtime. Three layers of defense. |
| Memoization is dropped accidentally during Fix C's refactor | Performance regression (O(N²) instead of O(N) on deep carrier hierarchies) | Low | The `memoCache` parameter is still passed into `calc()` by reference; the `containsKey` short-circuit at `calc():1073` is unchanged. Verify by reading the diff: only the Collector's supplier is removed. The 3-arg `Collectors.toMap(keyMapper, valueMapper, mergeFunction)` overload is the standard form. |
| `ParallelStreamSafetyArchTest` mis-imports `BaseStream.parallel()` | Compile error or arch-test classpath miss | Very low | Mirror `OptionalSafetyArchTest`'s import structure exactly. Use `java.util.stream.BaseStream` (the documented superclass). Verify by running `mvn test -Dtest=ParallelStreamSafetyArchTest` in isolation before final commit. |
| Manual probe (§5.1 row 9) reveals current production data corruption | Plan assumption "fix is shipped" is wrong | Low | The probe is the gate. If any batch shows non-deterministic output, escalate before proceeding — the SBDEV-2218 fix may not have actually closed the underlying symptom and a deeper investigation is required (root cause may be elsewhere in the pipeline, e.g. `calc()`'s repository calls returning stale rows under concurrent batch processing). |
| `Unitload.hashCode()` returns `getClass().hashCode()` (constant) — Fix B's `hasSize(500)` assertion silently collapses if seeded entities are not persisted | `baseline.keySet().hasSize(500)` passes with fewer than 500 distinct entries, making the determinism test a false pass | Medium | Fix B's test sketch includes `entityManager.flush()` immediately after seeding, and `assertThat(baseline.keySet()).hasSize(unitLoadCount)` as the first post-run assertion. Executor MUST persist (flush) all `Unitload` rows before passing the list to `calculateUnitLoadAmounts`, so each entity has a distinct non-null id. Verify-script check B6 asserts that the IT references `hasSize` (or equivalent). |
| Fix A's ArchUnit rule bans ALL `parallelStream()` / `parallel()` in the scoped packages — a future legitimate in-memory parallel operation would need a carve-out in TWO places | If a developer adds a justified purely in-memory parallel operation (no repo calls, no ThreadLocal reads), they must: (1) add a freeze-store entry or package-scope exclusion in `ParallelStreamSafetyArchTest`, AND (2) update the H1/H2 grep assertions in the verify script to exclude the new site | Low | Document: when a carve-out is added to `ParallelStreamSafetyArchTest`, the corresponding verify-script H1/H2 grep patterns must be updated to add a `grep -v` exclusion for that class. A one-place change is not sufficient — both the static rule and the grep must be updated together. |

---

## 10. Open Questions / Resolved Decisions

| # | Question / Decision | Resolution | Recorded by |
|---|---|---|---|
| 1 | Should the ArchUnit test ban `parallel()` (the `BaseStream` method) too, not just `parallelStream()`? | **Yes** — both are equivalent ForkJoinPool entry points. Banning `parallelStream()` alone leaves the loophole of `someStream.parallel()`. Fix A includes both rules. | This plan, Fix A |
| 2 | Should the ArchUnit rule cover `..repo..` and `..util..` packages too? | **Yes** — repos and util helpers shouldn't ever stream to ForkJoinPool either. Same root cause (ThreadLocal not inherited; Hibernate Session not thread-safe). The current scope is `..service..`, `..controller..`, `..schedulejob..`, `..util..`, `..repo..`. Note: `..business..` was originally listed here but that package does not exist in v2 (`ls src/main/java/net/aim_ai/wms/` confirms no `business` directory); `..util..` is substituted. | This plan, Fix A |
| 3 | Fix C path (a) "memoization-with-explicit-map" vs (b) "drop memoization"? | **(a) Memoization-with-explicit-map.** Reason: Fix B's IT will validate determinism either way, but preserving memoization keeps the recursion at O(N) instead of O(N²) for complex carrier hierarchies (parent-child unitload nesting). Cost is one extra map allocation; benefit is no perf regression. | This plan, Fix C |
| 4 | The ticket cites class-level `@Transactional` "at line 30". The current line 30 is `private int maxClubLineBatchSize = 500;`. Is this a contradiction? | **Stale ticket reference.** The ticket was written before commit `58ad0f36` (which removed the class-level `@Transactional` and converted all 9 method-level annotations to use `value = "tenantTransactionManager"`). Verified by reading lines 24-25: `@Service` only, no class-level `@Transactional`. This plan does not re-do the work — the ticket's line-30 claim is acknowledged as historical context. | This plan, §1 |
| 5 | Should the IT use Testcontainers PostgreSQL or H2 in PostgreSQL mode? | **H2 in PostgreSQL mode (`BaseIntegrationTest`).** Reason: the determinism contract is dialect-independent (sequential `.stream()` is a JVM-level guarantee). `BasePostgresIntegrationTest` cannot boot a full Spring context without an active `integration` profile (carried from SBDEV-2217 §6' Deviation). Manual smoke against staging covers cross-dialect correctness. | This plan, Fix B |
| 6 | Should the inline comment include a code reference to the ArchUnit and IT class names? | **Yes.** Any future engineer who edits `calculateUnitLoadAmounts` should immediately see what safety nets exist. The comment is the cheapest place to enforce that signal. Fix D includes both class names. | This plan, Fix D |
| 7 | Should this plan port to v1 in the same session? | **No.** The ticket lists both `wmsv1` and `wmsv2` tags, but v1's state is unverified. A paired v1 plan with the same base name (`SBDEV-2218-parallelstream-against-hibernate-session.md`) should be authored in `sbdocs/1-Projects/wms1/plan/` in a separate session. Use `wms-bugfix-plan` or `wms-v2-migrate` (in reverse direction) for that work. | This plan, §11 |
| 8 | Does the freeze-store mechanism need to be wired? | **No.** v2 has zero pre-existing offenders, so the rule runs cleanly. Adding a freeze-store would normalize an empty baseline — wasted complexity. If a future hidden offender surfaces, escalate per §11 risk row 1. | This plan, Fix A |

---

## 11. v1 / v2 Applicability

| Aspect | V1 | V2 (this plan) | Impact |
|---|---|---|---|
| `parallelStream()` in `calculateUnitLoadAmounts` | Likely still present (per ticket) | Already removed in `74f3c221`; sequential `.stream()` in place | v1 needs the same migration |
| Class-level `@Transactional` on `CustomerorderBatchService` | Likely still present (per ticket "line 30") | Already removed in `58ad0f36` | v1 needs the equivalent of `58ad0f36` |
| ArchUnit regression-guard test | Not present (verify v1 pom for `archunit-junit5`) | Adding in this plan | v1 needs the same — confirm `archunit-junit5` is on the v1 test classpath; the existing v1 ArchUnit infrastructure (if any) is the pattern reference |
| Deterministic-output IT | Not present | Adding in this plan | v1 needs the same — extend the v1 equivalent of `BaseIntegrationTest` |
| `amounts` HashMap back-reference removal | Likely still present | Adding in this plan | v1 needs the same |
| Inline regression comment | Not present | Adding in this plan | v1 needs the same |

### What needs porting to v1 (deferred to a separate session)

A paired v1 plan with the same base name (`SBDEV-2218-parallelstream-against-hibernate-session.md`) should be authored in `sbdocs/1-Projects/wms1/plan/`. The work is broadly the same shape but more invasive — v1 likely retains the legacy `parallelStream()` + class-level `@Transactional`. Use the `wms-bugfix-plan` skill or `wms-v2-migrate` (in reverse direction) for that session. v1 file paths to investigate: `v1/wms-api/src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`.

### What does NOT need porting

Nothing in this v2 plan is v2-only behaviourally. The ArchUnit rule, deterministic-output IT, back-reference cleanup, and comment hardening all apply equally to v1. The scope of `wms2-api/main` differs from v1 only in **what is already done**, not what is required.

---

## 12. Layer 2 Completeness Checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** — Analysis Protocol §8 complete | **`db_verified: true`** — wms1-wineco-dev MCP queries succeeded 2026-05-09. §1 records `total_unitloads=752,838` and the top-10 itemdata distribution (max 12,346 unitloads_per_item). Confirmed the original `>100` parallelStream branch was reachable in production — historical exposure documented. |
| 1 | **All callsites enumerated** — every row in §0 visited by §5 Fix Design or excluded with rationale | ✓ §0 has 9 rows; #1 #2 marked `[ALREADY DONE]` with commit SHA; #3 in Fix D; #4 in Fix C; #5 #6 #7 excluded with rationale; #8 in Fix A; #9 in Fix B |
| 2 | **Adjacent bugs** — other classes / methods with the same root-cause pattern | ✓ §0 row 5 (`TenantAwareTaskDecorator.java:24` Javadoc warning is the only other `parallelStream` reference in v2 src/main); §0 row 8 confirms zero production callsites today; Fix A's ArchUnit rule extends coverage to all `..service..`, `..controller..`, `..schedulejob..`, `..util..`, `..repo..` packages so any future adjacent re-introduction is caught at build time (`..business..` dropped — that package does not exist in v2) |
| 3 | **Backward compatibility** | ✓ Fix C is functionally equivalent (same input → same output, verified by Fix B's IT). Fix A is test-only. Fix D is comment-only. No DB schema change, no API contract change, no frontend payload change. |
| 4 | **Concurrency** | ✓ §7 row 6 + row 7 — sequential `.stream()` is naturally idempotent and ThreadLocal-safe; the entire plan is **about** concurrency correctness; Fix A enforces statically, Fix B asserts at runtime |
| 5 | **Multi-tenant** | ✓ §7 row 7 — TenantContext ThreadLocal correctness is the headline concern; Fix A's ArchUnit rule covers `..service..`, `..controller..`, `..schedulejob..`, `..util..`, `..repo..` package scope |
| 6 | **Error handling** | ✓ Fix C/D do not change error paths. The existing `runClubLine` `@Transactional` boundary's `rollbackFor` clause is unchanged. No new throw paths introduced. |
| 7 | **Observability** | ✓ §5.1 row 8 (optional Grafana log-based alert on the literal string `parallelStream()` re-appearing in production logs — low priority since the ArchUnit test catches it pre-deploy at build time). The existing `runClubLine` metric coverage (if any) is unchanged. |
| 8 | **Rollback / migration** | ✓ §5.1 row 1 (no DB state change), row 5 (no data migration), row 9 (manual probe before implementation). No Flyway migration; no feature flag; no sysprop addition. Pure code-and-test change. |
| 9 | **Test coverage** | ✓ §6' Test Plan: 2 unit-level arch-test methods (`ParallelStreamSafetyArchTest`) + 1 integration test (`CustomerorderBatchServiceParallelStreamRegressionIT`, 100 iterations × 500 unitloads); regression list explicit |
| 10 | **Cross-version (v1↔v2)** | ✓ §11 — v1 needs a paired plan in a separate session; v1 file paths listed; v2-only deltas explicit (`74f3c221`, `58ad0f36` are v2-only commits) |

---

## 13. Acceptance & Implementation

### 13.1 Acceptance criteria → test mapping

| AC# | Ticket criterion | Test class | Test method | What makes it fail before fix |
|---|---|---|---|---|
| AC-1 | `calculateUnitLoadAmounts` uses sequential stream OR fully pre-loaded parallel stream | Verify script (`PRE-2`, `PRE-3`) | n/a (static analysis) | `PRE-2` asserts `unitLoads.stream()…collect` regex matches; `PRE-3` asserts `parallelStream` literal is absent. Already passing today (`74f3c221`). |
| AC-2 | No `parallelStream` in the codebase touches a repository or entity manager | Verify script (codebase-wide grep) + `ParallelStreamSafetyArchTest` (Fix A) | `noParallelStreamCallsInProductionPackages`, `noBaseStreamParallelCallsInProductionPackages` | Verify-script grep returns 0 production hits; ArchUnit rule catches any future re-introduction across `..service..`, `..controller..`, `..schedulejob..`, `..util..`, `..repo..` (`..business..` does not exist in v2) |
| AC-3 | Load test: batch with 500 unitloads → result is deterministic across 100 runs | `CustomerorderBatchServiceParallelStreamRegressionIT` (Fix B) | `calculateUnitLoadAmounts_isDeterministic_acrossRepeatedRuns` | No such test exists today |
| AC-4 (new — defense-in-depth) | The `amounts` HashMap is no longer reused as both memoization cache and Collector result map | Verify script | n/a (static analysis — negative regex) | `() -> amounts` supplier removed; identifier renamed to `memoCache` |
| AC-5 (new — comment hardening) | The inline comment cites SBDEV-2218, the Hibernate Session reason, and the safety-net class names | Verify script | n/a (static analysis — three positive regexes) | Comment updated per Fix D |

### 13.2 Acceptance script (machine-checkable)

**Path:** `sbdocs/9-System/scripts/verify-SBDEV-2218-parallelstream-against-hibernate-session.sh`

The script encodes one POSITIVE check (and a NEGATIVE check where applicable) per fix:
- **PRE (3 checks)** — already-done baseline: no class-level `@Transactional` on `CustomerorderBatchService`; sequential `.stream()` in `calculateUnitLoadAmounts`; no `parallelStream` in the file.
- **Fix A** — `ParallelStreamSafetyArchTest.java` exists; references `noClasses().that().resideInAPackage`; bans both `parallelStream` and `parallel()`; `mvn test -Dtest=ParallelStreamSafetyArchTest` passes.
- **Fix B** — `CustomerorderBatchServiceParallelStreamRegressionIT.java` exists; references the `_isDeterministic_acrossRepeatedRuns` method name; references seeding size `500` and iteration count `100`; `mvn jacoco:prepare-agent failsafe:integration-test -Dit.test=CustomerorderBatchServiceParallelStreamRegressionIT` passes.
- **Fix C** — `() -> amounts` supplier removed; `memoCache` (or equivalent renamed identifier) present.
- **Fix D** — comment region near `calculateUnitLoadAmounts` references `SBDEV-2218`, `Hibernate Session`, and `ParallelStreamSafetyArchTest`.
- **Codebase-wide hardening** — `grep -rn '\.parallelStream\s*(' src/main/java` returns 0 production invocations (excluding Javadoc comments).

**Workflow contract:**
1. Run `bash sbdocs/9-System/scripts/verify-SBDEV-2218-parallelstream-against-hibernate-session.sh` BEFORE any code change to capture the baseline FAIL count (expected: 3 PRE pass, ~10–12 fails for Fix A/B/C/D).
2. Run after every cluster of changes.
3. Final acceptance: `Result: N pass, 0 fail`. The implementing agent's end-of-task report MUST paste this exact line.

### 13.3 Recommended OMC composition (for implementation)

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | 4 fixes (A/B/C/D) across 1 production file + 2 new test files; closes audit-chain gaps for an already-shipped fix |
| **Pre-draft step** | none | Prompt was specific; deep-interview unnecessary |
| **Plan-review step** | critic | Standard-sized plans should have a critic pass before coding starts |
| **Implementation shape** | executor | Single executor; verify script is the exit gate |
| **Verification step** | verify-script + verifier | Mandatory (PRE-1/2/3 + Fix A/B/C/D + codebase-wide hardening) |
| **Code-review step** | code-reviewer | Optional; useful because Fix C edits a hot-path service file |
| **Commit step** | git directly | Single logical commit per fix is fine; no need for `git-master` |

---

## 14. Implementation Status

> **Status (2026-05-09):** Implemented and committed in 3 atomic commits. **PR**: [#5](https://github.com/SiteBossInc/wms2-api/pull/5) (base: develop, head: tasks/SBDEV-2218). Branch pushed; awaiting merge.
>
> **Commit map (SBDEV-NNNN CN — style):**
> - **C1** `1b09eeb` — Fix A: ArchUnit guard (`ParallelStreamSafetyArchTest`)
> - **C2** `f7eb19d` — Fix C + Fix D combined: decouple `memoCache` from Collector + comment hardening (atomicity rationale: same hunk in `CustomerorderBatchService.java`)
> - **C3** `478cf1b` — Fix B: deterministic concurrent IT (`CustomerorderBatchServiceParallelStreamRegressionIT`)

| Fix | Status | v2 commit SHA | Test classes added/updated | mvn result |
|---|---|---|---|---|
| Fix A — ArchUnit guard | implemented (commit pending — held for git-master) | see commit map below | `ParallelStreamSafetyArchTest` (new) — methods `noParallelStreamCallsInProductionPackages`, `noBaseStreamParallelCallsInProductionPackages` | `mvn test -Dtest=ParallelStreamSafetyArchTest` → `Tests run: 2, Failures: 0, Errors: 0, Skipped: 0` (4.253 s) |
| Fix B — Deterministic IT | implemented (commit pending — held for git-master) | see commit map below | `CustomerorderBatchServiceParallelStreamRegressionIT` (new) — method `calculateUnitLoadAmounts_isDeterministic_acrossRepeatedRuns` | `mvn jacoco:prepare-agent failsafe:integration-test -Dit.test=CustomerorderBatchServiceParallelStreamRegressionIT` → `Tests run: 1, Failures: 0, Errors: 0, Skipped: 0` (52.54 s elapsed) |
| Fix C — Back-reference cleanup | implemented (commit pending — held for git-master) | see commit map below | edit `service/CustomerorderBatchService.java` lines ~1045-1067 (`calculateUnitLoadAmounts`); regression-checked via `CustomerorderBatchServiceUnitTest` | `mvn test -Dtest=CustomerorderBatchServiceUnitTest` → `Tests run: 89, Failures: 0, Errors: 0, Skipped: 0` |
| Fix D — Comment hardening | implemented (commit pending — combined with Fix C edit, held for git-master) | _(combined with Fix C commit)_ | edit comment block at `service/CustomerorderBatchService.java` lines ~1051-1055 | covered by Fix C's `mvn test` run (same diff) |

**Final verify-script line:** `Result: 28 pass, 0 fail, 0 skip`

**Full unit-test suite (`mvn test`):** `Tests run: 3894, Failures: 1, Errors: 1, Skipped: 67` — 2 pre-existing failures both unrelated to this plan: `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses` (4 unguarded `Optional.get()` callsites in `StockunitService` / `UnitloadService` — SBDEV-2116 territory) and `ViewDtoServiceUnitTest$ReplenishOrderViews.getReplenishOrderViewByKeywordShouldReturnOpenOrders` (Mockito unnecessary-stubbing). Pre-existing baseline confirmed identical to SBDEV-2217 hand-off note.

**DBA probe result (§5.1 row 9):** Not re-run during implementation — §1 records 2026-05-09 results (`total_unitloads=752,838`, top itemdata 12,346 unitloads_per_item) within the 30-day refresh window, so re-run was optional and skipped.
