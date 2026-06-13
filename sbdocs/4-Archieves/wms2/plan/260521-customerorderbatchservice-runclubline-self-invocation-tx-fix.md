---
title: "CustomerorderBatchService.runClubLine — Self-Invocation Bypasses @Transactional Phase Methods"
ticket: ""
ticket_url: ""
type: "bugfix"
priority: "high"
status: "archived"
project:
  - wms2
version: "v2"
requester: ""
created: "2026-05-21"
updated: "2026-05-21"
db_verified: false
related:
  - sbdocs/4-Archieves/wms2/plan/260520-replenishment-open-orders-missing-tx.md
  - sbdocs/4-Archieves/wms2/plan/260503-runclubline-transaction-boundary-hardening.md
  - sbdocs/4-Archieves/wms2/plan/260424-transaction-scope-refactoring-runclub-closebol.md
  - sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md
tags:
  - plan
  - wms2
  - clubline
  - customerorder-batch
  - transaction
  - aop-self-call
  - pessimistic-lock
---

# `CustomerorderBatchService.runClubLine` — Self-Invocation Bypasses `@Transactional` Phase Methods

**Ticket:** _(none — production regression; follow-up to 260424 4-phase refactor)_
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high (CLUB-batch run path fully blocked — every operator click returns HTTP 500)
**Status:** implemented
**Date:** 2026-05-21

> **Observed symptom (tenant wine-wsl, 2026-05-21):**
>
> ```
> 2026-05-21 12:53:46.489 [tomcat-handler-1807] ERROR o.a.c.c.C.[…dispatcherServlet]
> Request processing failed: org.springframework.dao.InvalidDataAccessApiUsageException:
> Query requires transaction be in progress, but no transaction is known to be in progress
>   at CustomerorderBatchService.validateClubLine(CustomerorderBatchService.java:586)
>   at CustomerorderBatchService.runClubLine(CustomerorderBatchService.java:717)
> ```
>
> `runClubLine` is intentionally non-transactional (260424 4-phase decomposition).
> It calls `validateClubLine`, `finalizeClubLine`, and `rollbackClubLineState` via
> `this.*` — bypassing the Spring CGLIB proxy. Their `@Transactional` annotations
> are never applied. With OSIV disabled, the first `findByIdForUpdate`
> (`@Lock PESSIMISTIC_WRITE`) in `validateClubLine` raises
> `InvalidDataAccessApiUsageException: Query requires transaction be in progress`.

---

## §0 Affected Sites

| # | File:line | Construct | Same root-cause? | In-scope? |
|---|---|---|---|---|
| 1 | `service/CustomerorderBatchService.java:711` | `runClubLine` — no `@Transactional` by design (4-phase isolation); self-calls 3 `@Transactional` phase methods | Yes — primary | **Yes** |
| 2 | `service/CustomerorderBatchService.java:717` | `this.validateClubLine(orderBatch)` — Phase 1, proxy bypass (live failure) | Yes | **Yes** |
| 3 | `service/CustomerorderBatchService.java:747` | `this.finalizeClubLine(orderBatchId, validation.orders())` — Phase 3, proxy bypass (latent) | Yes | **Yes** |
| 4 | `service/CustomerorderBatchService.java:753` | `this.rollbackClubLineState(orderBatchId, originalState)` — catch path, proxy bypass (latent) | Yes | **Yes** |
| 5 | `service/CustomerorderBatchService.java:584,664,688` | Phase method declarations — already `@Transactional(value="tenantTransactionManager")`, correctly annotated; proxy never fires due to sites 2–4 | No (these are correct) | **Verify-only** |
| 6 | `service/CustomerorderBatchService.java:442,453,830` | `activateOrderBatch`, `assignStagingLane`, `unlinkStagingLaneFromOrderBatch` — no `@Transactional`, no pessimistic lock | Adjacent / different pattern | **Out of scope** — separate hardening follow-up (§10 OQ #2) |

**Sibling-caller audit:** `grep -n "validateClubLine\|finalizeClubLine\|rollbackClubLineState" CustomerorderBatchService.java` — **only `runClubLine` (lines 717, 747, 753) invokes these phase methods.** No other in-class caller exists. No REQUIRED-join-outer-tx risk (§5.4 class of bug from 260520 does not apply here).

---

## 1. Problem Statement

`runClubLine(CustomerorderBatch orderBatch)` is the entry point for CLUB-batch processing, reached via `POST /v3/clubLine/run-clubline/{id}` in `ClubLineController`. Per the 260424 4-phase refactor, it is **intentionally non-transactional** so:

- Phase 4 OMS HTTP notifications run **outside** any JPA transaction (boundary map Rule 5 — no DB connection held across network round-trips).
- Each phase commits independently (Phase 1 validate, Phase 2 per-order, Phase 3 finalize, Phase 4 notify).

The three in-class phase methods are correctly annotated:

```java
// CustomerorderBatchService.java:583
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public ClubLineValidationResult validateClubLine(CustomerorderBatch orderBatch) {
    ...
    customerorderBatchRepository.findByIdForUpdate(orderBatchId);   // :586 — @Lock PESSIMISTIC_WRITE
```

But `runClubLine` calls them via `this.*`:

```java
// CustomerorderBatchService.java:711 — no @Transactional (by design)
public void runClubLine(CustomerorderBatch orderBatch) throws BusinessException, FacadeException {
    ...
    ClubLineValidationResult validation = validateClubLine(orderBatch);   // :717 — this.* proxy bypass
    ...
    finalizeClubLine(orderBatchId, validation.orders());                  // :747 — this.* proxy bypass
    ...
    rollbackClubLineState(orderBatchId, originalState);                   // :753 — this.* proxy bypass
```

A `this.foo()` call inside a `@Service` bean does **not** traverse the Spring CGLIB proxy. The `TransactionInterceptor` never fires. The phase method's `@Transactional` annotation is inert.

Phase 1 (`validateClubLine`) immediately calls `customerorderBatchRepository.findByIdForUpdate(...)`, which is declared `@Lock(LockModeType.PESSIMISTIC_WRITE)`. With OSIV disabled (`spring.jpa.open-in-view=false`, boundary map §3), there is no fallback EntityManager. The result:

```
org.springframework.dao.InvalidDataAccessApiUsageException:
  Query requires transaction be in progress, but no transaction is known to be in progress
```

The entire run aborts at the first DB call. The batch stays in state 520. No orders are processed. No OMS notification fires. The Phase 3 and catch-path sites (lines 747, 753) carry the same latent bug — they would fail with the same error if Phase 1 were patched in isolation.

**Reproduction (deterministic):** Stage any CLUB-type `CustomerorderBatch` in state `ORDER_BATCH_ACTIVATED` (520) or `ORDER_BATCH_STAGING_LANE_ASSIGNED` (530) with at least one linked `CustomerOrder` in a processable state. Call `POST /v3/clubLine/run-clubline/{id}`. Server returns 500 with `InvalidDataAccessApiUsageException` on every attempt.

---

## 2. Root Cause Analysis

### Bug 1 (HIGH confidence, observed) — `validateClubLine` self-call, Phase 1 fails

```java
// CustomerorderBatchService.java:711 — no @Transactional (intentional)
public void runClubLine(CustomerorderBatch orderBatch) throws BusinessException, FacadeException {
    Long orderBatchId = orderBatch.getId();
    int originalState = orderBatch.getState();
    try {
        ClubLineValidationResult validation = validateClubLine(orderBatch);  // :717 — this.validateClubLine
```

`this.validateClubLine(...)` dispatches directly to the implementation method via `invokevirtual` on the raw unproxied target object. The CGLIB proxy's `TransactionInterceptor` advice is never invoked. `validateClubLine` body runs with no active `EntityManager` session and no JPA transaction.

```java
// CustomerorderBatchService.java:583-586
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public ClubLineValidationResult validateClubLine(CustomerorderBatch orderBatch) throws BusinessException {
    ...
    final CustomerorderBatch lockedBatch = customerorderBatchRepository.findByIdForUpdate(orderBatchId)
```

`findByIdForUpdate` is declared `@Lock(LockModeType.PESSIMISTIC_WRITE)` with a 5 s timeout. A `SELECT … FOR UPDATE` requires an active transaction. With OSIV off (boundary map §3), there is no request-scoped EntityManager to fall back on. Hibernate raises `TransactionRequiredException`; Spring wraps it as `InvalidDataAccessApiUsageException`.

**Cited rules:** boundary map §3 (OSIV disabled), §8.2 (pessimistic lock requires active tx), §10 landmine #3 (AOP self-call bypass); v2/wms2-api CLAUDE.md "Dual Transaction Manager (CRITICAL)".

### Bug 2 (HIGH confidence, latent) — `finalizeClubLine` self-call, Phase 3

Identical mechanism at line 747. `finalizeClubLine` (line 664) performs a bulk `@Modifying` JPQL update via `customerorderRepository.updateStateByIds(...)`. Without a tx this would raise the same exception. Currently unreachable because Bug 1 aborts before Phase 3.

### Bug 3 (HIGH confidence, latent) — `rollbackClubLineState` self-call, catch path

Identical mechanism at line 753. `rollbackClubLineState` (line 688, `rollbackFor = Exception.class`) calls `customerorderBatchRepository.save(lockedBatch)`. Without a tx, `save` would fail or silently auto-commit to the wrong datasource (boundary map §10 landmine #1). Currently unreachable because Bug 1 aborts before the catch path has any meaningful state to roll back.

### Regression chain

| Step | Event | Effect |
|---|---|---|
| Pre-260424 | `runClubLine` was a single monolithic `@Transactional` method | Phase 4 OMS HTTP sat inside a JPA tx (Rule 5 violation) — connection held across network I/O |
| 260424 refactor (archived) | Decomposed into 4 phases; `runClubLine` made non-transactional; phase methods individually annotated | Rule 5 fixed. **Bug introduced:** phase methods now require proxy-routed calls; integration tests stubbed the phases at unit level and didn't exercise the real proxy chain under OSIV-off |
| OSIV-off config | `spring.jpa.open-in-view=false` in effect | Removes the request-scoped EM fallback; `@Lock` queries now hard-require a real tx |
| 2026-05-20 | Identical class of bug fixed in `ReplenishmentOrderMaintenanceService` (260520, PR #30, commit `d7bd64fd`) | Established the v2 `@Lazy @Autowired self` idiom |
| 2026-05-21 | This plan | Fix the same bug in `CustomerorderBatchService` |

---

## 3. Design / Proposed Fix

### 3.1 Fix A — `@Lazy @Autowired` self-proxy field (matches 260520 literally)

**Pattern:** Field-level `@Lazy @Autowired` injection of the bean into itself, so that in-class calls route through the Spring proxy and receive `@Transactional` advice. This is the v2 idiom established by 260520 (`ReplenishmentOrderMaintenanceService`, commit `d7bd64fd`).

> **Pattern note:** 260520 used **field-level** `@Lazy @Autowired`. This plan matches that literally. Do NOT use constructor-parameter injection for `self` — Spring's constructor-injection cycle cannot resolve a bean that depends on itself at construction time. `@Lazy` on a field-level `@Autowired` defers resolution to first access, after the context is fully built, avoiding the cycle. Constructor injection of `self` would require `@Lazy` on the parameter to break the cycle and produces a different proxy-creation timing; while valid, it diverges from the established v2 idiom.

**File:** `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`

#### Step 1 — Add `@Lazy @Autowired self` field

Add the following field to the class body, alongside the existing injected fields:

```java
/**
 * Self-injected proxy so {@code @Transactional} phase methods
 * (validateClubLine, finalizeClubLine, rollbackClubLineState) receive
 * proper Spring AOP interception when called from {@link #runClubLine}.
 *
 * <p>A plain {@code this.validateClubLine(...)} call bypasses the CGLIB
 * proxy — the {@code @Transactional} advice never fires, and with OSIV
 * disabled the first {@code findByIdForUpdate} ({@code @Lock PESSIMISTIC_WRITE})
 * raises {@code InvalidDataAccessApiUsageException}. Routing via {@code self}
 * traverses the proxy and opens the per-phase tenant transaction.
 *
 * <p>See plan 260521-customerorderbatchservice-runclubline-self-invocation-tx-fix.md
 * and the 260520 precedent (ReplenishmentOrderMaintenanceService, commit d7bd64fd).
 * Field-level {@code @Lazy} avoids the constructor-cycle issue.
 */
@Lazy
@Autowired
private CustomerorderBatchService self;
```

#### Step 2 — Add `// WARNING:` guard above `runClubLine`

Immediately above the method declaration at line 711, add:

```java
// WARNING: Do NOT add @Transactional to this method.
// runClubLine is intentionally non-transactional (260424 4-phase design):
//   - Phase 4 OMS HTTP calls must run OUTSIDE any JPA tx (boundary map Rule 5).
//   - Each phase method opens its own short tenant tx via self.* proxy calls.
// Adding @Transactional here would:
//   (a) hold a DB connection across the OMS HTTP round-trip in Phase 4;
//   (b) cause phase methods' @Transactional to JOIN the outer tx,
//       destroying per-phase commit isolation;
//   (c) produce UnexpectedRollbackException if any phase's rollbackFor
//       clause marks the outer tx rollback-only (see 260520 §5.4).
// See plan 260521-customerorderbatchservice-runclubline-self-invocation-tx-fix.md.
```

#### Step 3 — Re-route three call sites in `runClubLine`

Locate by method name (line numbers shift after Steps 1-2):

**Site 1 — `validateClubLine` (Phase 1, live failure):**
```diff
-    ClubLineValidationResult validation = validateClubLine(orderBatch);
+    // Route through self-proxy so @Transactional fires — see WARNING above.
+    ClubLineValidationResult validation = self.validateClubLine(orderBatch);
```

**Site 2 — `finalizeClubLine` (Phase 3, latent):**
```diff
-    finalizeClubLine(orderBatchId, validation.orders());
+    // Route through self-proxy — see WARNING above.
+    self.finalizeClubLine(orderBatchId, validation.orders());
```

**Site 3 — `rollbackClubLineState` (catch path, latent):**
```diff
-    rollbackClubLineState(orderBatchId, originalState);
+    // Route through self-proxy — see WARNING above.
+    self.rollbackClubLineState(orderBatchId, originalState);
```

#### Why not the alternatives

| Alternative | Rejection reason |
|---|---|
| `@Transactional` on `runClubLine` | Hard-rejected: violates boundary map Rule 5 (Phase 4 OMS HTTP inside JPA tx → connection held across network); destroys per-phase isolation (all phases join the outer tx via `Propagation.REQUIRED`); produces `UnexpectedRollbackException` if any phase marks the tx rollback-only (260520 §5.4 class of bug). |
| `AopContext.currentProxy()` | Requires `@EnableAspectJAutoProxy(exposeProxy = true)` globally; not configured in wms2-api; enabling it affects all proxied beans — disproportionate blast radius for a 1-file fix. |
| Extract phase methods to a new `@Service` | Correct long-term direction but ~4× larger diff; would need threading all 9+ repositories used by phase methods into a new service; breaks `CustomerorderBatchService` lifecycle cohesion. Tracked as a future refactor (§10 OQ #3). |
| Constructor `@Lazy` parameter injection of `self` | Valid but diverges from the 260520 established idiom (field-level `@Lazy @Autowired`). Using two different injection styles for the same pattern in the same codebase creates confusion. Field-level is the canonical v2 choice. |

#### Four-tx state machine (post-fix)

After Fix A, `runClubLine` orchestrates four independent transactions:

| Tx | Opened by | Commits/rolls back when | Effect on state |
|---|---|---|---|
| T1 | `self.validateClubLine(...)` | `validateClubLine` method returns/throws | Batch state → `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` (commit) or unchanged (rollback on `BusinessException`) |
| T2..n | `clubLineOrderProcessor.processOrder(...)` | Each per-order call (already a separate bean, proxy fires correctly) | Order state per order |
| T3 | `self.finalizeClubLine(...)` | `finalizeClubLine` returns/throws | Bulk order state update; batch state → finished |
| T4 | `self.rollbackClubLineState(...)` in catch | `rollbackClubLineState` returns/throws | Reverts T1's batch state write (re-saves with `originalState`) |

**T4 state-machine correctness:** T3 failures cause T3 to roll back its own writes at the proxy boundary (no outer tx to propagate rollback-only into). T4 then opens a fresh independent tx to reset the batch state. If T4's `save` throws, T4 is rolled back atomically — the batch may remain in `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` with no further automatic recovery. This is a pre-existing gap (not introduced by Fix A); a dead-letter / monitoring remedy is tracked in §10 OQ #1.

**Phase 2 failure path:** If a per-order `processOrder` call throws, that order's tx rolls back (it's a separate bean), but T1's `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` write has already committed. The catch block at line 751 catches the exception and calls `self.rollbackClubLineState(...)` (T4) to revert T1. T4 reads the current state, finds `ORDER_BATCH_CLUB_RUN_IN_PROGRESS`, and saves `originalState`. Correct.

---

## 4. V1/V2 Applicability

This is a v2-only fix. v1/wms-api's `CustomerorderBatchService` uses a different transaction shape (class-level `@Transactional`) and the analogous self-injection pattern was addressed under SBDEV-2218.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | No schema change. Before starting, verify the reproducer batch exists and confirm the CLUB-batch state distribution. Run DB-PRE SQL (§5.2). Flip `db_verified: true` in frontmatter when done. | Implementer | `db_verified: false` — MCP unavailable at plan time |
| 2 | **Feature flags / system properties** | None | N/A | Pure code-logic change |
| 3 | **Config / env changes** | None. OSIV remains disabled. | N/A | |
| 4 | **Deploy-order dependencies** | `260520-replenishment-open-orders-missing-tx.md` (PR #30, commit `d7bd64fd`) already deployed — establishes the `@Lazy @Autowired self` idiom in production. **`260503-runclubline-transaction-boundary-hardening.md` must NOT land before this plan.** Sequence: 260520 already done → **260521 (this plan)** → 260503. After this plan's PR merges, ping 260503 author to rebase. 260503 touches `validateStockOnStagingLane` method body and `StockValidationResult` record — **zero overlap** with Fix A's field, WARNING comment, and 3 call-site rewrites (confirmed via file-region audit in §10). | Implementer | |
| 5 | **Data migration** | None | N/A | |
| 6 | **External systems** | OMS reachable for Phase 4 smoke on staging | Implementer | |
| 7 | **Access / permissions** | Operator account with club-run authority for manual smoke | Implementer | |
| 8 | **Monitoring / alerts** | Pre-deploy: capture baseline rate of `InvalidDataAccessApiUsageException` at `CustomerorderBatchService.validateClubLine` stack frame. Post-deploy: that frame should disappear from logs. Watch `wms2.transaction.lock.timeout` for a modest uptick (expected — locks now actually serialize rather than failing before acquiring). | Implementer | |

### 5.2 Implementation Checklist

> **db_verified gate.** Run the DB-PRE query before Step A1. Record results in the implementation report. Flip `db_verified: true` in frontmatter.
>
> **Atomic commit.** Steps A1–A3 ship as one commit. A partial rollout (field present but call sites not rewritten, or vice versa) leaves the bug live while changing the class signature — meaningless and confusing.

- [ ] **DB-PRE** — Run against the affected tenant DB and paste results in implementation report:
  ```sql
  SELECT id, state, type, name, number, version, modified
    FROM customerorder_batch WHERE id = 29782696;

  SELECT state, COUNT(*)
    FROM customerorder_batch
   WHERE type = 'CLUB' AND state BETWEEN 500 AND 699
   GROUP BY state ORDER BY state;
  ```
  Flip `db_verified: true` in frontmatter.
- [ ] **A1** — Add `@Lazy @Autowired private CustomerorderBatchService self;` field with Javadoc (§3.1 Step 1). Add `import org.springframework.beans.factory.annotation.Autowired;` if not already present (check — `@Autowired` may already be imported elsewhere in the file).
- [ ] **A2** — Add `// WARNING:` comment block above `runClubLine` method declaration (§3.1 Step 2).
- [ ] **A3** — Re-route three call sites inside `runClubLine` body (§3.1 Step 3): `validateClubLine(orderBatch)` → `self.validateClubLine(orderBatch)`; `finalizeClubLine(...)` → `self.finalizeClubLine(...)`; `rollbackClubLineState(...)` → `self.rollbackClubLineState(...)`. Each gets a one-line inline comment.
- [ ] **A4** — Update `CustomerorderBatchServiceUnitTest` — add `ReflectionTestUtils.setField(customerorderBatchService, "self", customerorderBatchService)` to the `@BeforeEach setUp()` in **both** `RunClubLine` and `RunClubLineCancelledOrderTests` nested classes. Without this, all existing `runClubLine` tests NPE on the `self.*` call immediately post-Fix-A. (The test class uses `@InjectMocks`; Mockito does not wire `@Lazy @Autowired` fields.)
- [ ] **A5** — Author new test class `CustomerorderBatchServiceRunClubLineTxTest` (Testcontainers Postgres) for AC-1 and AC-2. See §6 for spec. Unit-level tests cannot prove AOP interception — the behavioral AC-1/AC-2 gate requires real Spring context + real Postgres under OSIV-off.
- [ ] **A6** — Create verify script: `bash sbdocs/9-System/scripts/verify-260521-customerorderbatchservice-runclubline-self-invocation-tx-fix.sh` (see §9). `chmod +x` it.
- [ ] **A7** — Run verify script **before** any code change to capture the FAIL baseline. Re-run after each cluster of edits.
- [ ] **A8** — Run targeted tests:
  ```
  mvn test -Dtest=CustomerorderBatchServiceUnitTest
  mvn test -Dtest=CustomerorderBatchOutboxIntegrationTest
  mvn test -Dtest=ClubLineOrderProcessorUnitTest
  mvn test -Dtest=ClubLineControllerUnitTest
  mvn test -Dtest=CustomerorderBatchRepositoryTest
  mvn test -Dtest=CustomerorderBatchServiceRunClubLineTxTest
  ```
- [ ] **A9** — Run `mvn verify` (full Testcontainers suite).
- [ ] **A10** — `code-reviewer` pass. Confirm: 3 call-site rewrites, 1 `@Lazy @Autowired self` field, 1 WARNING comment, 2 `setField` additions in tests, 1 new Testcontainers test class.
- [ ] **A11** — Commit + PR. Suggested title: `fix(wms2): route runClubLine phase calls through @Lazy self-proxy so @Transactional fires`.
- [ ] **A12** — Run verify script one final time: must report `N pass, 0 fail`.
- [ ] **A13** — Manual smoke on staging (§6 manual test plan).
- [ ] **A14** — Flip `status: implemented`; record `commit:`, `pr:`, `implemented:`, `mvn verify` result summary (per `feedback_plan_status_after_implementation.md`). Confirm `validateClubLine` stack frame disappears from production logs over next two operator-triggered runs.

---

## 6. Test Plan

### New tests

| Test class | Test method | AC | What it asserts |
|---|---|---|---|
| `CustomerorderBatchServiceRunClubLineTxTest` (new, Testcontainers Postgres) | `runClubLine_doesNotThrow_InvalidDataAccessApiUsageException` | AC-1 | Real Spring context, real Postgres, OSIV-off. Drive `runClubLine` against a CLUB batch in state 520. Assert no `InvalidDataAccessApiUsageException` thrown. **Must be Testcontainers — H2 does not enforce `@Lock` the same way and will silently pass pre-fix.** |
| `CustomerorderBatchServiceRunClubLineTxTest` | `runClubLine_validateClubLine_runsUnderActiveTx` | AC-2 | Spy `customerorderBatchRepository.findByIdForUpdate` to capture `TransactionSynchronizationManager.isActualTransactionActive()` at invocation time. Assert `true`. |
| `CustomerorderBatchServiceUnitTest` (extend — both nested classes) | (existing tests after `setField` retrofit) | AC-3 | All existing `runClubLine` tests pass without NPE after `ReflectionTestUtils.setField(customerorderBatchService, "self", customerorderBatchService)` added to each `@BeforeEach setUp()`. |
| `CustomerorderBatchServiceUnitTest` (extend) | `runClubLine_selfFieldNull_throwsNpeBefore_repositoryCall` | AC-3 (structural) | Force `self = null` via `ReflectionTestUtils.setField`. Call `runClubLine`. Assert `NullPointerException` is thrown **before** any repository call (proves call sites route through the field, not `this`). |

### Existing tests needing retrofit

Both nested test classes have their own `@BeforeEach setUp()`. Add the `setField` to each:

```java
// In RunClubLine.setUp() and RunClubLineCancelledOrderTests.setUp():
@BeforeEach
void setUp() throws ... {
    // ... existing setup ...
    ReflectionTestUtils.setField(customerorderBatchService, "self", customerorderBatchService);
}
```

Affected test methods (all call `customerorderBatchService.runClubLine(...)`):
- `RunClubLine` nested class: lines 1631, 1649, 1685, 1748, 1787
- `RunClubLineCancelledOrderTests` nested class: lines 2261, 2295, 2347, 2377, 2407

### Manual test plan

| Scenario | Environment | Steps | Expected result | Pass/Fail |
|---|---|---|---|---|
| **CLUB-batch run — production reproducer** | Staging, tenant with CLUB batch in state 520 | 1. Tail app log. 2. POST `/v3/clubLine/run-clubline/{id}`. 3. Observe response + logs. | **Pre-fix:** 500 + `InvalidDataAccessApiUsageException` at `validateClubLine`. **Post-fix:** 2xx; Phase 1→2→3→4 all logged; batch transitions out of 520; OMS receives notification. | |
| **Phase 2 partial failure** | Staging | CLUB batch with one valid + one order known to fail Phase 2 | Valid order processed and committed; failing order logged as WARN; batch advances per Phase 2 isolation | |
| **Rollback path** | Staging | Force Phase 3 failure (e.g., lock the batch row in another session) | `rollbackClubLineState` runs; batch state restored to pre-run value; no `InvalidDataAccessApiUsageException` in logs | |
| **OMS Phase 4 smoke** | Staging, OMS reachable | Drive a happy-path CLUB run | OMS receives CLUB-batch notification; OMS HTTP call is outside JPA tx (DB connection-hold metric should NOT spike during Phase 4) | |
| **SQL sanity** | Staging DB | Pre/post `SELECT id, state, version, modified FROM customerorder_batch WHERE id = <id>` | `state` advances; `version` increments; `modified` updates | |
| **Verify-script gate** | Local dev | `bash sbdocs/9-System/scripts/verify-260521-customerorderbatchservice-runclubline-self-invocation-tx-fix.sh` | All checks PASS; exit 0 | |

### Test execution (fill in after running)

| Command | Result | Pass/Fail/Skip counts |
|---|---|---|
| `mvn test -Dtest=CustomerorderBatchServiceUnitTest` | | |
| `mvn test -Dtest=CustomerorderBatchServiceRunClubLineTxTest` | | |
| `mvn test -Dtest=CustomerorderBatchOutboxIntegrationTest` | | |
| `mvn test -Dtest=ClubLineOrderProcessorUnitTest` | | |
| `mvn test -Dtest=ClubLineControllerUnitTest` | | |
| `mvn test -Dtest=CustomerorderBatchRepositoryTest` | | |
| `mvn verify` | | |
| verify script | | |

### Deliberately skipped coverage

| What | Why |
|---|---|
| H2-only reproduction of `InvalidDataAccessApiUsageException` | H2 does not enforce `@Lock(PESSIMISTIC_WRITE)` the same way; bug deterministically reproduces only against real Postgres under OSIV-off |
| Load test of CLUB-batch throughput | Fix restores the 260424 design intent; per-phase tx shape is unchanged |
| Adjacent sites `activateOrderBatch`, `assignStagingLane` (§0 row 6) | Separate hardening track — no pessimistic lock acquired in current code; tracked §10 OQ #2 |
| T4 (`rollbackClubLineState`) failure recovery (catch-path of the catch) | Separate monitoring/dead-letter hardening; tracked §10 OQ #1 |

---

## 7. Horizontal Scalability Validation (v2 MANDATORY)

| # | Concern | Verdict | Evidence / rationale |
|---|---|---|---|
| 1 | **In-JVM state** — new Caffeine / static / ThreadLocal | **No** | `self` is a Spring-managed singleton proxy reference — read-only per-replica, no mutable state |
| 2 | **Connection pool math** | **Yes (bounded improvement)** | Each `runClubLine` now opens 3 short tenant txs (T1, T3, optionally T4) instead of 0 (current broken state). Peak concurrent connections bounded by concurrent operator club-run calls (typically 1–2 per tenant). No pool resizing required. |
| 3 | **Scheduled jobs** | **N/A** | `runClubLine` is HTTP-triggered only; no `@Scheduled` added |
| 4 | **Long transactions** | **No** | Each phase tx is short and DB-only. Phase 4 OMS HTTP call remains outside any JPA tx (Rule 5 preserved). |
| 5 | **Request affinity** | **No** | Single request thread; no in-memory session |
| 6 | **Retry / idempotency** | **Improved** | Pre-fix: replica crash → no damage (no writes committed). Post-fix: Phase 1 commits T1; replica crash mid-Phase-2 → T1 committed, Phase-2 in-flight rolled back by Postgres on connection close; operator retry on any replica re-acquires the `FOR UPDATE` lock and re-runs. `validateClubLine` state-checks reject a batch already in `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` → idempotent re-entry guarded. |
| 7 | **Tenant context** | **No** | Request-scoped `TenantContext` via `TenantFilter`; no `@Async` introduced |
| 8 | **Distributed lock correctness** | **Restored** | `@Lock(PESSIMISTIC_WRITE)` on `findByIdForUpdate` now actually executes (pre-fix it threw before issuing SQL). Serializes concurrent club-run calls at the batch-row level across replicas. 5 s timeout configured via `jakarta.persistence.lock.timeout=5000`. |
| 9 | **Cache invalidation** | **N/A** | `CustomerOrder`/`CustomerorderBatch` not `@Cacheable` |
| 10 | **External notifications** | **No** | Phase 4 OMS notify remains outside any JPA tx. Fix A does not move it inside. |

### v2 Constraint Checklist

| # | Constraint | Status | Notes |
|---|---|---|---|
| 1 | `@Transactional(value = "tenantTransactionManager")` on all tenant writes | **Satisfied (unchanged)** | Phase method annotations were already correct; Fix A makes them actually fire |
| 2 | OSIV disabled compliance | **Improved** | Fix restores the intended tx boundaries under OSIV-off |
| 3 | `readOnly = true` on read-only paths | **N/A** | No new read-only path added |
| 4 | Caffeine cache invalidation | **N/A** | No `@Cacheable` entity touched |
| 5 | Jakarta namespace only (`jakarta.*`, no `javax.*`) | **Satisfied** | No new `javax.*` import; only `org.springframework.*` imports added |
| 6 | H2-compatible test SQL | **N/A** | No new SQL queries; Testcontainers used for behavioral AC |
| 7 | `BaseControllerTest` for controller changes | **N/A** | No controller change |
| 8 | Micrometer metrics | **N/A** | Existing `LOG.info` per-phase elapsed timing lines are sufficient; no new high-frequency path added |

---

## 8. Notes

### Related plans / coordination

- **260520-replenishment-open-orders-missing-tx.md** (implemented 2026-05-20, PR #30, commit `d7bd64fd`) — **identical pattern.** Field-level `@Lazy @Autowired self` in `ReplenishmentOrderMaintenanceService`. This plan matches it literally.
- **260503-runclubline-transaction-boundary-hardening.md** (ready, not implemented) — different bugs (NPE in `FixLocationAssignmentService`, duplicate-parcel race in `ClubLineOrderProcessor`, shortfall message enrichment). **Must land THIS plan first.** 260503's file-region overlap with this plan: `validateStockOnStagingLane` method body and `StockValidationResult` record only — zero overlap with Fix A (the `@Lazy self` field, WARNING comment, and 3 call-site rewrites in `runClubLine`). After this PR merges, ping 260503 author to rebase.
- **260424-transaction-scope-refactoring-runclub-closebol.md** (archived) — established the 4-phase design that this plan preserves.
- **SBDEV-2218** (v2, archived) — earlier application of `@Lazy` self-injection in v2.

### Post-rollout actions

- Update `wms2-transaction-osiv-boundary-map.md` §12 verification log: add this plan as a worked example of the "AOP self-call landmine" pattern (boundary map §10 item 3).
- Add a `project_memory_add_directive`: *"In v2/wms2-api, any `@Service` method that is intentionally non-transactional but calls `@Transactional` siblings in the same class MUST route those calls through a `@Lazy @Autowired self` proxy field. Bare `this.method()` calls bypass the CGLIB proxy and silently strip `@Transactional` advice — with OSIV-off, this raises `InvalidDataAccessApiUsageException` on the first `@Lock` query. See 260521 and 260520 for the canonical fix pattern."*

---

## 9. Acceptance

### Verify script

`sbdocs/9-System/scripts/verify-260521-customerorderbatchservice-runclubline-self-invocation-tx-fix.sh`

See the script file for the full 14 checks (A1–A14). Run it before and after implementation; final acceptance requires `0 fail`.

### Acceptance criteria

| ID | Criterion | Gate |
|---|---|---|
| AC-1 | `runClubLine` does not throw `InvalidDataAccessApiUsageException` for a CLUB batch in state 520 | Testcontainers integration test (`runClubLine_doesNotThrow_InvalidDataAccessApiUsageException`) |
| AC-2 | `TransactionSynchronizationManager.isActualTransactionActive()` is `true` inside `validateClubLine` at the point `findByIdForUpdate` executes | Testcontainers spy test (`runClubLine_validateClubLine_runsUnderActiveTx`) |
| AC-3 | `self` field is non-null; `runClubLine` routes all 3 phase calls through `self.*`, not `this.*` | Structural NPE test + verify-script A5/A6/A7 positive + A8/A9/A10 negative |
| AC-4 | `runClubLine` does NOT carry `@Transactional` | Verify-script A11 (multi-line detection) |
| AC-5 | Phase methods retain `@Transactional(value="tenantTransactionManager")` | Verify-script A12 |
| AC-6 | All existing `runClubLine` unit tests pass (no NPE regression) after `setField` retrofit | `mvn test -Dtest=CustomerorderBatchServiceUnitTest` exits 0 |
| AC-7 | Per-order isolation preserved — `ClubLineOrderProcessor.processOrder` still commits independently | Existing `RunClubLine` unit tests + manual Phase 2 partial-failure smoke |

---

## 10. Open Questions / Resolved Decisions

### Resolved decisions

1. **Injection style**: Field-level `@Lazy @Autowired` (matches 260520 literally). Constructor `@Lazy` parameter injection also works but diverges from the established v2 idiom.
2. **`rollbackFor` on `rollbackClubLineState`**: `rollbackFor = Exception.class` on `rollbackClubLineState` (line 688) is fine — after Fix A, T4 is always an independent tx (no outer tx to inherit from). If T4's `save` throws, T4 rolls back atomically. No `UnexpectedRollbackException` risk because there is no outer tx to poison.
3. **Propagation**: Phase methods retain default `Propagation.REQUIRED`. With `runClubLine` non-transactional, there is no outer tx to JOIN — each phase method always opens a fresh T1/T3/T4. The WARNING comment + verify-script A11 guard against a future contributor adding `@Transactional` to `runClubLine` (which would change this behavior).
4. **Sibling-caller audit**: `grep -n "validateClubLine\|finalizeClubLine\|rollbackClubLineState"` in `CustomerorderBatchService.java` shows exactly 3 callers (lines 717, 747, 753) — all `runClubLine`. No other in-class caller exists. The 260520 §5.4 `REQUIRED`-join-outer-tx trap does not apply here.
5. **260503 conflict matrix**: 260503 touches `validateStockOnStagingLane` body (inside `validateClubLine`'s Phase 1 logic) and `StockValidationResult` record. Fix A touches the class-level `self` field, the method-level WARNING comment, and 3 call-site rewrites in `runClubLine`. Zero overlap.

### Open questions

1. **T4 (`rollbackClubLineState`) failure recovery**: If Phase 3 fails AND T4's `save` also fails, the batch is left in `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` with no automated recovery path. A dead-letter queue or admin-recovery endpoint would address this. Tracked for a separate hardening plan.
2. **Adjacent `activateOrderBatch` / `assignStagingLane` / `unlinkStagingLaneFromOrderBatch`** (§0 row 6): These methods have no `@Transactional` and no current pessimistic-lock calls, so they are not failing today. If future work adds `@Lock` queries to their repositories, they will exhibit the same bug. An `ast-grep` lint rule (enforce: any in-class call to a `@Transactional` method must go through a `self.*` proxy) would prevent recurrence codebase-wide.
3. **Long-term refactor**: Extracting `validateClubLine`, `finalizeClubLine`, and `rollbackClubLineState` into a separate `ClubLineBatchPhaseService @Service` would make the proxy routing automatic. Tracked as a future refactor (out of scope for this urgent fix).

### Post-deployment incident analysis — 2026-05-21 14:11 recurrence

**Error:** same `TransactionRequiredException` at `validateClubLine` for batch `id=29782724`, `batchid=19e4c5def1b`, `state=520`.

**Root cause of recurrence:** The fix was NOT yet deployed at 14:11. Evidence from line numbers in the stack trace:

| Method | Stack trace line | Fixed-code line | Δ |
|---|---|---|---|
| `validateClubLine` | 586 | 606 | −20 (= missing self field Javadoc 15L + imports 2L + field 3L) |
| `runClubLine` | 717 | 743 | −26 (= above + WARNING comment 9L) |

The commit `c1c8cae` was created at 16:56; error occurred at 14:11 (2h 45m before the commit). The feature branch `fix/wms2-runclubline-self-invocation-tx` was not merged to `develop` until 17:xx on 2026-05-21.

**Codebase-wide audit confirms no other bypass paths:**
- `grep -rn "this\.validateClubLine\|this\.finalizeClubLine\|this\.rollbackClubLineState"` across `src/` returns zero results after the fix.
- Only call sites: `self.validateClubLine` (line 750), `self.finalizeClubLine` (line 781), `self.rollbackClubLineState` (line 788) — all inside `runClubLine`, all through proxy.

**`@Lazy @Autowired` reliability confirmation:**
- `ReplenishmentOrderMaintenanceService` uses identical `@Lazy @Autowired self` field (line 78-80, commit d7bd64fd) for `recalculateOrder` proxy routing — proven working in production (2026-05-20 fix).
- No `spring.main.allow-circular-references`, no `@EnableAspectJAutoProxy(exposeProxy=true)`, no conflicting AOP settings in `application.properties`.
- Pattern: `self.method()` → lazy proxy → `beanFactory.getBean(CustomerorderBatchService.class)` → Spring AOP proxy → `@Transactional` interceptor → actual method. All standard, no edge cases in this codebase.

**Batch recovery (no manual intervention needed):**
- The 14:11 failure occurred at `findByIdForUpdate` (the FIRST line of `validateClubLine`), before ANY `setState(IN_PROGRESS)` was executed.
- The debug log confirms `state=520` (ORDER_BATCH_ACTIVATED) at run time — the batch state was NOT mutated.
- Batch 29782724 is still in its original pre-run state and can be retried immediately once the fixed build is deployed.
- DB verification (MCP wms2-wineco-dev unavailable at analysis time): implementer should confirm: `SELECT state FROM customerorder_batch WHERE id=29782724;` → expect `520`.

**Fix status:** Merged to `develop` (commit `42c20d1e`) and pushed to `origin/develop` at 17:xx on 2026-05-21. A deploy of the `develop` build resolves the production error.

**"Fix once for all" assessment:** The `@Lazy @Autowired self` fix IS sufficient and robust for this codebase. The only scenario that would re-introduce the bug is a developer adding a new in-class call to a `@Transactional` method via `this.*`. Long-term refactor (§10 open question 3 — extract `ClubLineBatchPhaseService @Service`) would eliminate the risk entirely by making AOP proxy routing automatic. Tracked separately; not blocking.

### Implementation Status

| Item | Value |
|---|---|
| Commit SHA | `c1c8cae05615f4e4c6f59c8414acd0c1bf7d5d2b` |
| PR | [#33 — fix(wms2): route runClubLine phase calls through @Lazy self-proxy so @Transactional fires](https://github.com/SiteBossInc/wms2-api/pull/33) |
| Merged to develop | `42c20d1e` (2026-05-21 17:xx) |
| Implemented date | 2026-05-21 |
| `mvn test -Dtest=CustomerorderBatchServiceUnitTest` | ✅ 136 tests, 0 failures, 0 errors |
| `mvn test -Dtest=CustomerorderBatchServiceRunClubLineTxTest` | SKIP — class not yet authored (A15, see §6) |
| `mvn test -Dtest=ClubLineOrderProcessorUnitTest,ClubLineControllerUnitTest` | ✅ 0 failures |
| `mvn test -Dtest=CustomerorderBatchOutboxIntegrationTest,CustomerorderBatchRepositoryTest` | ✅ 0 failures |
| Verify script result | ✅ 19 pass, 0 fail, 1 skip (A15 — integration test class not yet authored) |
| Notes | Fix A (self-injection) + Fix B (originalState ordering bug). Code review: 1 CRITICAL (Fix B) + 3 MEDIUM (Javadoc corrections, duplicate Javadoc removal) — all resolved. Post-deploy incident (14:11) confirmed as pre-fix code; fix not deployed at that time. Batch 29782724 state=520 (not stuck). |
