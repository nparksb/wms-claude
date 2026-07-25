---
title: "SBDEV-2116: Unguarded Optional.get() Fix — v2 Port"
ticket: "SBDEV-2116"
ticket_url: ""
type: "bug-fix"
priority: "high"
status: "archived"
project:
  - wms2-api
version: ""
requester: ""
created: "2026-05-03"
updated: "2026-05-03"
related:
  - "sbdocs/4-Archieves/wms1/plan/SBDEV-2116-unguarded-optional-get-fix-plan.md"
tags:
  - plan
  - v2-port
db_verified: true
---

# SBDEV-2116: Unguarded Optional.get() Fix — v2 Port

**Ticket:** SBDEV-2116
**Project:** wms2-api | **Version:** — | **Type:** bug-fix
**Priority:** High
**Status:** ready
**Date:** 2026-05-03

**V1 Source Plan:** `sbdocs/4-Archieves/wms1/plan/SBDEV-2116-unguarded-optional-get-fix-plan.md`
**V1 Commits:** `5c4fc5d` (Phase 0+1) · `cca3cc9` (Phases 2–4) · `7e4d7ad` (throws propagation) · `271958e` (test throws)

---

## 1. Problem Statement

v2/wms2-api has two confirmed crash sites and a missing global exception handler safety net:

1. **`MobileMoveStockService.selectSource:L136`** — `unitLoadOpt.orElse(null)` followed by `unitLoad.getStoragelocationId()` at L144. When a user scans a non-existent unit load label, `unitLoad` is null → `NullPointerException` → HTTP 500. This is the same crash site as the original SBDEV-2116 ticket, present at a different line in v2.

2. **`SyspropService.createSystemProperty:L67`** — `syspropOptional.get()` throws `NoSuchElementException` before reaching `if (sysProp == null)`. The create-if-absent branch is dead code. Every call to `createSystemProperty` for a non-existent key crashes.

3. **`RestExceptionHandler`** — Missing global handlers for `BusinessException` and `NoSuchElementException`. Either can escape a controller and produce a raw HTTP 500 with stack trace.

---

## 2. Root Cause Analysis

### Summary

v2 has reduced the Optional.get() problem dramatically (624 `.orElseThrow()` calls vs ~90 `.get()` calls remaining) because v2 was built with better patterns. Most remaining `.get()` calls are:
- Caught `try { .get() } catch (NoSuchElementException) { return null; }` patterns (technically safe, anti-pattern)
- `isPresent()` / ternary-guarded patterns

But two genuinely unguarded bugs remain, plus two missing RestExceptionHandler safety-net handlers.

### Affected Locations

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | `src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java` | end of class | Add `BusinessException` and `NoSuchElementException` handlers |
| 2 | `src/main/java/net/aim_ai/wms/service/SyspropService.java` | 52–90 | `createSystemProperty`: `.get()` before null-check (dead branch) |
| 3 | `src/main/java/net/aim_ai/wms/service/mobile/MobileMoveStockService.java` | 136 | `selectSource`: `.orElse(null)` → NPE at L144 |

### V1 → V2 Applicability Table

| V1 Fix | Description | V2 Verdict | Rationale |
|---|---|---|---|
| FIX-1 Phase 0 | Add `BusinessException` global handler | **Needed** | Missing from v2 RestExceptionHandler |
| FIX-2 Phase 0 | Add `NoSuchElementException` global handler | **Needed** | ~90 `.get()` remain; safety net for any unguarded |
| FIX-3 Phase 0 | Add `NullPointerException` global handler | **Not needed** | Leave to Spring default 500; NPE indicates programmer bug; adding handler masks defects in logs |
| FIX-4 Phase 1 | `MobileMoveStockService.selectSource` stockUnit path | **Not needed** | v2:L106 already null-guarded by `if (stockUnit != null)` |
| FIX-5 Phase 1 | `MobileMoveStockService.selectSource` unitLoad path | **Needed** | v2:L136 `.orElse(null)` → NPE at L144 |
| FIX-6 Phase 1 | `StockunitService.transferStock` findByLabelid | **Not needed** | v2:L151 already `.orElseThrow(EntityNotFoundException)` |
| FIX-7 Phase 1–4 | ~770 remaining `.get()` calls | **Partial** | v2 has only ~90; most caught/guarded; Phase 2 sweep |
| FIX-8 (7e4d7ad) | `throws BusinessException` propagation to callers | **Not needed** | v2 methods already declare throws; new fixes use RuntimeException |
| FIX-9 (271958e) | `throws BusinessException` in 36 test files | **Not applicable** | JUnit 5 — different pattern, no equivalent needed |

---

## 3. Design / Proposed Fix

### 3.1 Phase 0 — RestExceptionHandler: Two New Global Handlers

**Existing baseline (already present):**
- `EntityNotFoundException` → HTTP 404 ProblemDetail, title "Entity Not Found" (L117–123)
- `ObjectOptimisticLockingFailureException` → HTTP 409
- `PessimisticLockingFailureException` → HTTP 409

**Missing (to add):**

```java
@ExceptionHandler(BusinessException.class)
protected ResponseEntity<ProblemDetail> handleBusinessException(BusinessException ex) {
    LOG.warn("Business exception: {}", ex.getMessage());
    ProblemDetail problemDetail = ProblemDetail.forStatusAndDetail(HttpStatus.UNPROCESSABLE_ENTITY, ex.getMessage());
    problemDetail.setTitle("Business Rule Violation");
    return ResponseEntity.status(HttpStatus.UNPROCESSABLE_ENTITY).body(problemDetail);
}

@ExceptionHandler(NoSuchElementException.class)
protected ResponseEntity<ProblemDetail> handleNoSuchElement(NoSuchElementException ex) {
    LOG.error("Unguarded Optional.get() — no value present: {}", ExceptionUtils.getStackTrace(ex));
    ProblemDetail problemDetail = ProblemDetail.forStatusAndDetail(HttpStatus.NOT_FOUND, "Entity not found");
    problemDetail.setTitle("Optional Get Safety Net");
    return ResponseEntity.status(HttpStatus.NOT_FOUND).body(problemDetail);
}
```

**Important: Controller precedence.** Controllers that already have `catch (BusinessException e)` locally — e.g., `MoveStockController:L53,L104`, `ClubLineController:L95,119,146,169,276` — intercept `BusinessException` before the global handler sees it. Those return HTTP 200 `{"errors":[...]}`. The new global handler fires only for controllers that do NOT have a local `catch (BusinessException)`. This is the intended safety-net behavior.

**NoSuchElementException title distinction:** Uses "Optional Get Safety Net" (not "Entity Not Found") to distinguish from the `EntityNotFoundException` handler in logs and observability. `LOG.error` (not warn) flags this as a programmer defect — every NSE that reaches the global handler means an unguarded `.get()` was left in production code.

**NullPointerException deliberately omitted.** NPE → leave to Spring's default error mapping (HTTP 500). Adding a NPE handler would mask defects that operations currently catch via stack-trace alerts.

**Files changed:** `RestExceptionHandler.java`

---

### 3.2 Phase 1 Fix NEW-1 — SyspropService.createSystemProperty (L67)

**`SyspropService.createSystemProperty` — bug and context:**

The method has create-if-absent semantics with three branches:
1. Key not found → create new `Sysprop`
2. Key found + `reinitialize=true` → update groupname, description, hidden, sysvalue
3. Key found + `reinitialize=false` + existing description empty → update description, hidden only
4. Key found + `reinitialize=false` + existing description non-empty → save with no changes

Currently, `.get()` at L67 throws `NoSuchElementException` before the null check, making branch 1 unreachable.

**Before:**
```java
Optional<Sysprop> syspropOptional = syspropRepository.findBySyskeyAndClientIdAndWorkstation(key, client.getId(), workstation);
Sysprop sysProp = syspropOptional.get();  // throws NSE when key absent; null-check is dead code

if (sysProp == null) {
    sysProp = new Sysprop();
    // ... populate fields
```

**After:**
```java
Optional<Sysprop> syspropOptional = syspropRepository.findBySyskeyAndClientIdAndWorkstation(key, client.getId(), workstation);
Sysprop sysProp = syspropOptional.orElse(null);  // correctly returns null when absent

if (sysProp == null) {
    sysProp = new Sysprop();
    // ... populate fields — now reachable
```

**`@Transactional` addition (also required):**

`createSystemProperty` currently has `@CacheEvict` only — no `@Transactional`. Add:

```java
@CacheEvict(value = "sysprops", key = "...")
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public void createSystemProperty(Client client, String workstation, String key, ...) {
```

**Why `@Transactional` is needed alongside the `.orElse(null)` fix:** `los_sysprop` has `CONSTRAINT uk8tcoe23qui9q3ancbhx662iqb UNIQUE (client_id, syskey, workstation)` (V1.0.01__wms_tables.sql:565). Without `@Transactional`, a concurrent second writer that also passes the `findBySyskeyAndClientIdAndWorkstation` empty check would attempt `save()` and receive `DataIntegrityViolationException` from the DB. With `@Transactional`, the second writer's transaction rolls back cleanly. The unique constraint is the correct duplicate-insert guard; `@Transactional` ensures proper rollback semantics.

**Self-invocation caveat (accept, document):** `getStringDefault` (L231) calls `createSystemProperty(...)` via a direct `this.` call. Spring's `@Transactional` proxy does NOT intercept self-invocations — the new transaction boundary will not apply on the `getStringDefault` → `createSystemProperty` path. This is acceptable because: (a) `getStringDefault` is a boot-time/lazy-init path invoked infrequently, (b) the unique constraint still protects against duplicate inserts at the DB level, (c) the fix still resolves the primary NSE bug on all paths. If transactional correctness on the self-invocation path is required in future, extract via `@Self` injection or a helper bean.

**`@CacheEvict` + `@Transactional` annotation order:** `@CacheEvict` is declared before `@Transactional`. Spring's default interceptor chain processes `@Transactional` first (outer) and `@CacheEvict` after method return (inner). This means cache is evicted after the transaction commits — the correct semantic. Do not reorder the annotations.

**Files changed:** `SyspropService.java`

---

### 3.3 Phase 1 Fix NEW-2 — MobileMoveStockService.selectSource (L136)

**Before:**
```java
Optional<Unitload> unitLoadOpt = unitloadRepository.findByLabelid(dto.getSource());
Unitload unitLoad = unitLoadOpt.orElse(null);
// ...
Location storageLocation = locationRepository.findById(unitLoad.getStoragelocationId())  // NPE if unitLoad null
```

**After (consistent with file pattern — EntityNotFoundException used throughout MobileMoveStockService):**
```java
Optional<Unitload> unitLoadOpt = unitloadRepository.findByLabelid(dto.getSource());
Unitload unitLoad = unitLoadOpt.orElseThrow(() -> new EntityNotFoundException("UnitLoad not found for label: " + dto.getSource()));
```

**Response format change (intentional):** Previously, a non-existent label caused NPE → HTTP 500. Post-fix, `EntityNotFoundException` propagates past `MoveStockController:L53`'s `catch (BusinessException e)` (which does not catch RuntimeException) → global `@ExceptionHandler(EntityNotFoundException.class)` → HTTP 404 ProblemDetail. This is a deliberate improvement aligned with REST semantics and v2's established `EntityNotFoundException` pattern.

**Frontend verification required:** The v2 mobile UI must handle HTTP 404 from `GET /selectSource/{input}`. Verify `wms2-mobile-ui`'s axios interceptor handles non-2xx responses for this endpoint before Phase 1 ships to production.

**Same-file `.orElse(null)` siblings — all GUARDED, no fix needed:**

| Line | Pattern | Guard |
|------|---------|-------|
| L233 | `storageLocation = storageLocationOpt.orElse(null)` | `if (storageLocation != null)` at L253 before use |
| L258 | `fixedLocationAssignment = fixedLocationAssignmentOpt.orElse(null)` | `if (fixedLocationAssignment == null)` immediately after |
| L283 | `destinationUnitLoad = destinationUnitLoadOpt.orElse(null)` | `if (destinationUnitLoad == null)` immediately after |
| L294 | `unitLoadType = unitLoadTypeOpt.orElse(null)` | `if (unitLoadType == null)` assigns fallback immediately after |

**Files changed:** `MobileMoveStockService.java`

---

### 3.4 Phase 2 — Systematic Sweep (follow-up sprint)

~90 remaining `.get()` calls across ~20 services. Verified breakdown:

**Already confirmed safe (guarded/caught):**
- `PickingorderService:L69`, `LocationTypeService:L46,60`, `PickingorderUnitloadService:L45` — caught `try { .get() } catch (NSE) { return null; }`
- `StockunitBusinessService:L96`, `UnitloadBusinessService:L92,94` — caught, logs error
- `SyspropService:L121,182,197,212,225` — caught `try { .get() } catch (NSE) { ... }`
- `ReplenishmentOrderMaintenanceService:L233,241,278` — `isPresent()` guarded
- `CustomerorderService:L513,570` — `isPresent()` guarded
- `PickingorderBusinessService:L413`, `MobileTruckLoadingService:L188,205,335` — ternary `isPresent() ? .get() : null`

**Needs manual sweep verification (~25 calls):**
- `ClientService:L58,71,105,119`
- `UserGroupService:L59,90`
- `AccessService:L133,205,217`
- `MobileReplenishService:L181,213,342,437,634,690,693,731,754,830,979`
- `MobilePickingService:L157,436`
- `MobileInfoService:L354`
- `MobilePalletizingService:L328,337`
- `SequenceTransactionService:L30`
- `MobileCycleCountService:L109,311,312`

Phase 0's `NoSuchElementException` global handler ("Optional Get Safety Net") acts as safety net for any unverified unguarded calls.

**CI guardrail (required, prevents regression):** Add ArchUnit rule to fail build on new `Optional.get()` calls outside test packages. Use `TransactionManagerArchTest.java` as template (at `src/test/java/net/aim_ai/wms/unit/config/`):

```java
@Test
void noUnguardedOptionalGet() {
    noClasses()
        .that().resideOutsideOfPackages("..unit..", "..integration..")
        .should().callMethod(java.util.Optional.class, "get")
        .check(classes);
}
```

---

## 4. V2-Specific Adaptation Notes

1. **Jakarta namespace:** `jakarta.persistence.*` throughout. All imports already correct in v2.
2. **`@Transactional` must specify tenant TM:** `value = "tenantTransactionManager"` for any tenant service write. Added to `createSystemProperty` in Phase 1.
3. **`EntityNotFoundException` (RuntimeException) preferred for entity-not-found:** v2 pattern throughout most services. Phase 1 NEW-2 uses `EntityNotFoundException` consistently with file.
4. **`BusinessException` extends `Exception` (checked):** `@ExceptionHandler(BusinessException.class)` in `@ControllerAdvice` is valid for checked exceptions in Spring MVC — the framework routes them correctly.
5. **Controller precedence:** Local `catch (BusinessException)` in controllers intercepts before `@ControllerAdvice`. New global handler is fallback only. Existing v2 controller error shapes are preserved.
6. **SLF4J parameterized logging:** `LOG.warn("message: {}", var)`. No string concatenation.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | `V1.0.01__wms_tables.sql` already applied; `UNIQUE (client_id, syskey, workstation)` on `los_sysprop` confirmed | — | N/A — constraint pre-exists |
| 2 | **Feature flags / system properties** | None required | — | N/A — pure code fix |
| 3 | **Config / env changes** | None | — | N/A |
| 4 | **Deploy-order dependencies** | Phase 0 can deploy independently; Phase 1 does not require Phase 0 to deploy first (`MoveStockController` already has local `catch (BusinessException)`) | — | Recommended order: Phase 0 first |
| 5 | **Data migration** | None | — | N/A |
| 6 | **External systems** | v2 mobile UI `wms2-mobile-ui` must handle HTTP 404 from `GET /selectSource/{input}` after Phase 1 NEW-2 | Dev | Verify axios interceptor before Phase 1 production deploy |
| 7 | **Access / permissions** | None | — | N/A |
| 8 | **Monitoring / alerts** | After Phase 0 ships, "Optional Get Safety Net" title in ProblemDetail responses provides log-level signal; existing ERROR log in NSE handler sufficient | — | N/A |

### 5.2 Implementation Checklist

**Phase 0:**
- [x] Add `handleBusinessException` to `RestExceptionHandler.java`
- [x] Add `handleNoSuchElement` to `RestExceptionHandler.java` (title "Optional Get Safety Net", LOG.warn)
- [x] Add A1 test: `RestExceptionHandlerUnitTest` → `HandleBusinessException` nested class
- [x] Add A2 test: `RestExceptionHandlerUnitTest` → `HandleNoSuchElement` nested class
- [x] Run `mvn test -Dtest=RestExceptionHandlerUnitTest` ✓

**Phase 1:**
- [x] Fix `SyspropService:L67` — `.get()` → `.orElse(null)`
- [x] Add `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` to `createSystemProperty`
- [x] Fix `MobileMoveStockService:L136` — `.orElse(null)` → `.orElseThrow(EntityNotFoundException)`
- [x] Add A3–A5 tests: `SyspropServiceUnitTest` → `CreateSystemProperty` nested class
- [x] Add A6 test: `MobileMoveStockServiceTest`
- [x] Run `mvn test -Dtest=SyspropServiceUnitTest,MobileMoveStockServiceTest` ✓
- [ ] Verify `wms2-mobile-ui` handles HTTP 404 from `GET /selectSource/{input}`

**Phase 2 (follow-up sprint):**
- [x] Add `OptionalSafetyArchTest.java` with `FreezingArchRule` banning `Optional.get()` in service package
- [x] Sweep ~25 unverified `.get()` calls (AccessService, MobilePickingService, MobileReplenishService, ClientService) — all confirmed guarded; no additional fixes needed
- [x] Fix `AccessService` L133/205/217: `isPresent()+get()+else-throw` → `orElseThrow()` (3 calls removed from frozen baseline)
- [x] 162 existing anti-pattern calls frozen in `src/test/resources/archunit_store/`; new violations fail build
- [x] Run `mvn test` ✓ — 3840 tests, 0 failures

---

## 6. Test Plan

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `RestExceptionHandlerUnitTest` | A1: `HandleBusinessException.shouldReturn422_withProblemDetailTitleBusinessRuleViolation` | `@ExceptionHandler(BusinessException.class)` returns HTTP 422 with ProblemDetail title "Business Rule Violation" |
| `RestExceptionHandlerUnitTest` | A2: `HandleNoSuchElement.shouldReturn404_withProblemDetailTitleOptionalGetSafetyNet` | `@ExceptionHandler(NoSuchElementException.class)` returns HTTP 404 with ProblemDetail title "Optional Get Safety Net" |
| `SyspropServiceUnitTest` | A3: `CreateSystemProperty.shouldCreateNewSysprop_whenKeyNotFound` | `findBySyskeyAndClientIdAndWorkstation` returns empty → `syspropRepository.save()` called with new entity; no NSE thrown |
| `SyspropServiceUnitTest` | A4: `CreateSystemProperty.shouldUpdateFields_whenKeyExistsAndReinitializeTrue` | Present Optional + `reinitialize=true` → `save()` called with updated groupname/description/hidden/sysvalue |
| `SyspropServiceUnitTest` | A5a: `CreateSystemProperty.shouldUpdateDescription_whenKeyExistsAndReinitiializeFalse_andExistingDescriptionIsNull` | Present Optional + `reinitialize=false` + existing `description=null` → `save()` called with description set |
| `SyspropServiceUnitTest` | A5b: `CreateSystemProperty.shouldNotUpdateDescription_whenKeyExistsAndReinitializeFalse_andExistingDescriptionSet` | Present Optional + `reinitialize=false` + existing description non-empty → `save()` called but description field unchanged |
| `MobileMoveStockServiceTest` | A6: `selectSource_shouldThrowEntityNotFoundException_whenUnitLoadLabelNotFound` | `unitloadRepository.findByLabelid(label)` returns empty → `EntityNotFoundException` thrown; no NPE |

### Test patterns for RestExceptionHandlerUnitTest

The existing test class uses `TestableRestExceptionHandler extends RestExceptionHandler` with a `MockMvc` standalone setup. Follow the same pattern for new nested classes:

```java
@Nested
class HandleBusinessException {
    @Test
    void shouldReturn422_withProblemDetailTitleBusinessRuleViolation() throws Exception {
        // wire a dummy controller method that throws BusinessException
        mockMvc.perform(get("/test-business-exception"))
            .andExpect(status().isUnprocessableEntity())
            .andExpect(jsonPath("$.title").value("Business Rule Violation"));
    }
}

@Nested
class HandleNoSuchElement {
    @Test
    void shouldReturn404_withProblemDetailTitleOptionalGetSafetyNet() throws Exception {
        mockMvc.perform(get("/test-no-such-element"))
            .andExpect(status().isNotFound())
            .andExpect(jsonPath("$.title").value("Optional Get Safety Net"));
    }
}
```

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Mobile move-stock: scan non-existent label | staging | Mobile app: Move Stock → scan label `NONEXISTENT-999` | HTTP 404 ProblemDetail (not 500 stack trace) | |
| Mobile move-stock: scan valid label | staging | Mobile app: Move Stock → scan valid label | HTTP 200 with stock unit list (regression check) | |
| SyspropService: system boot creates new keys | staging | Deploy, check logs for `createSystemProperty` errors | No NSE errors in boot logs | |
| RestExceptionHandler: BusinessException escape | staging | Trigger a BusinessException path without local controller catch | HTTP 422 ProblemDetail with title "Business Rule Violation" | |
| RestExceptionHandler: NSE escape | staging | (If any residual `.get()` hits) | HTTP 404 ProblemDetail with title "Optional Get Safety Net" (not 500) | |

### Test execution (fill after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=RestExceptionHandlerUnitTest` | BUILD SUCCESS 2026-05-03 | 43 run, 0 fail, 0 skip |
| `mvn test -Dtest=SyspropServiceUnitTest,MobileMoveStockServiceTest` | BUILD SUCCESS 2026-05-03 | 43 run, 0 fail, 0 skip |
| `mvn test` (full suite after Phase 0+1) | BUILD SUCCESS 2026-05-03 | 3839 run, 0 fail, 67 skip |
| `mvn test` (full suite after Phase 2) | BUILD SUCCESS 2026-05-03 | 3840 run, 0 fail, 67 skip |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Phase 2 sweep unit tests | Phase 2 `.get()` calls are either caught/guarded patterns needing no behavioral change, or will be caught by Phase 0 NSE global handler until swept |
| `createSystemProperty` concurrency test (simultaneous saves) | DB unique constraint + `@Transactional` are the guards; unit tests cannot simulate real DB constraint violations without Testcontainers; defer to manual regression |
| `@Transactional` proxy self-invocation path | `getStringDefault` → `createSystemProperty` via `this.`; known limitation; DB unique constraint still protects |

---

## 7. Horizontal Scalability Validation

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce state that only exists in one replica? | No | RestExceptionHandler is stateless; `createSystemProperty` writes to DB (shared) |
| 2 | **Connection pool math** | Change per-request DB connection usage? | No | Adding `@Transactional` to `createSystemProperty` adds at most one additional short-lived connection per call; negligible impact |
| 3 | **Scheduled jobs** | Add or modify a cron job? | No | N/A |
| 4 | **Long transactions** | Hold a DB transaction across external I/O? | No | `createSystemProperty` is a single `findBy` + `save` — short-lived |
| 5 | **Request affinity** | Assume follow-up request lands on same replica? | No | N/A |
| 6 | **Retry / idempotency** | Rely on single-execution semantics? | No | `createSystemProperty` now correctly idempotent via DB unique constraint |
| 7 | **Tenant context** | Use `TenantContext` across async boundaries? | No | `createSystemProperty` is synchronous request-path; no async |
| 8 | **Distributed lock correctness** | Add pessimistic lock? | No | N/A |
| 9 | **Cache invalidation** | Write to cached entity? | Yes | `@CacheEvict` on `createSystemProperty` evicts the `sysprops` Caffeine cache keyed by `facilityCode:key`. Cache invalidation is per-replica — other replicas retain stale entries until their next Caffeine TTL expiry. This is pre-existing behavior unchanged by this fix. |
| 10 | **External notifications** | Send HTTP to external system inside transaction? | No | N/A |

### Evidence

| Concern # | What was done / verified | File:line or test reference |
|-----------|--------------------------|------------------------------|
| 9 | `@CacheEvict` pre-existing on `createSystemProperty`; TTL-based per-replica invalidation is acceptable for sysprop writes (infrequent, non-time-critical) | `SyspropService.java:51` |

---

## 8. Notes

### Pre-mortem: Scenarios that could cause this plan to fail

**Scenario A — Frontend breaks on HTTP 404 from selectSource:** Phase 1 NEW-2 changes `GET /selectSource/{input}` from HTTP 500 (current crash) to HTTP 404. If the v2 mobile UI's axios interceptor treats 4xx as silent failures (no error message shown), the user gets a blank screen rather than an error. Mitigation: verify `wms2-mobile-ui` axios error handling before Phase 1 production deploy. If the frontend cannot handle 404 quickly, use `BusinessException` as an interim measure (caught by `MoveStockController:L53` → HTTP 200 `{errors}`) and switch to `EntityNotFoundException` in a follow-up.

**Scenario B — `createSystemProperty` DataIntegrityViolationException on concurrent requests:** With the fix, two concurrent requests for the same (client, key, workstation) that both pass the `orElse(null)` empty check could both attempt `save()`. The second writer receives `DataIntegrityViolationException` (DB unique constraint). With `@Transactional`, the second writer's transaction rolls back. But `DataIntegrityViolationException` is not currently handled in `RestExceptionHandler` → propagates as HTTP 500. Mitigation: the self-invocation path (`getStringDefault` → `createSystemProperty`) is low-concurrency boot-time only. The request path (`SystemPropertyController`) is also admin-only and rarely concurrent. Accept as known risk; follow-up task: add `DataIntegrityViolationException` handler to RestExceptionHandler → HTTP 409.

**Scenario C — Phase 2 sweep uncovers CRITICAL unguarded `.get()` in mobile path:** ~25 unverified calls remain in `MobileReplenishService`, `MobilePickingService`. If any are unguarded, Phase 0 NSE handler catches them → HTTP 404 "Optional Get Safety Net" instead of HTTP 500. This is an improvement, but it may surface as "features failing silently" rather than 500 errors. Mitigation: ArchUnit rule (Phase 2) prevents new `.get()` additions; existing calls will be swept.

### Related decisions
- SBDEV-2102 v2 plan already handled `@Transactional` on `CustomerorderBatchService.finalizeBatchIfComplete` — same pattern applied here.
- v1 Phase 0 also added `NullPointerException` handler; v2 plan deliberately omits this — leaving NPE to Spring's default 500 preserves observability of real programmer bugs.
- v1 commits 7e4d7ad and 271958e (`throws BusinessException` propagation to callers and tests) — NOT needed in v2. v2 service signatures already declare `throws BusinessException` where needed; `EntityNotFoundException` (RuntimeException) requires no throws declaration.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance criteria

| AC | Test class | Method | What makes it fail before fix |
|---|---|---|---|
| A1 | `RestExceptionHandlerUnitTest` | `HandleBusinessException.shouldReturn422_withProblemDetailTitleBusinessRuleViolation` | No `@ExceptionHandler(BusinessException.class)` → Spring 500 |
| A2 | `RestExceptionHandlerUnitTest` | `HandleNoSuchElement.shouldReturn404_withProblemDetailTitleOptionalGetSafetyNet` | No `@ExceptionHandler(NoSuchElementException.class)` → Spring 500 |
| A3 | `SyspropServiceUnitTest` | `CreateSystemProperty.shouldCreateNewSysprop_whenKeyNotFound` | `syspropOptional.get()` throws NSE before save; test asserts `save()` called |
| A4 | `SyspropServiceUnitTest` | `CreateSystemProperty.shouldUpdateFields_whenKeyExistsAndReinitializeTrue` | `.get()` NSE prevents reaching else-if branch |
| A5a | `SyspropServiceUnitTest` | `CreateSystemProperty.shouldUpdateDescription_whenKeyExistsAndReinitializeFalse_andExistingDescriptionNull` | `.get()` NSE prevents reaching else-if branch |
| A5b | `SyspropServiceUnitTest` | `CreateSystemProperty.shouldNotUpdateDescription_whenKeyExistsAndReinitializeFalse_andExistingDescriptionSet` | `.get()` NSE prevents reaching else-if branch |
| A6 | `MobileMoveStockServiceTest` | `selectSource_shouldThrowEntityNotFoundException_whenUnitLoadLabelNotFound` | `orElse(null)` + NPE at L144 — NPE not `EntityNotFoundException` |

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | 3 files, 2 service fixes + 2 handler additions; single subsystem per phase |
| **Pre-draft step** | Done (this plan) | wms-v2-migrate with ralplan consensus |
| **Plan-review step** | critic | Standard+ requires critic before implementation |
| **Implementation shape** | executor | Phase 0 and Phase 1 are small, well-bounded; executor per phase |
| **Verification step** | verify-script + verifier (mandatory) | Run A1–A6 tests + `mvn verify` |
| **Code-review step** | code-reviewer | Exception handler changes affect all endpoints |
| **Commit step** | git-master | Two logical commits: Phase 0 and Phase 1 |

### 9.3 Implementation status (fill after each phase)

| Phase | v1 SHA | v2 Commit SHA | Tests added | `mvn test` result |
|---|---|---|---|---|
| Phase 0 | 5c4fc5d (partial) | — | A1, A2 | — |
| Phase 1 NEW-1 | 5c4fc5d (partial) | — | A3, A4, A5a, A5b | — |
| Phase 1 NEW-2 | 5c4fc5d (partial) | — | A6 | — |
| Phase 2 sweep | cca3cc9 (partial) | — | ArchUnit rule | — |
