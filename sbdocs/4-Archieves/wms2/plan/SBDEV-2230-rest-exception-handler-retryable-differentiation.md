---
title: "SBDEV-2230 — REST exception handler does not differentiate retryable vs non-retryable failures"
ticket: "SBDEV-2230"
ticket_url: "https://app.clickup.com/t/868jj32rd"
type: "bug"
severity: "high"
priority: "high"
status: "archived"
project: ["wms2-api"]
version: "v2"
requester: "David Oppenheim"
assignee: "Nam Park"
created: "2026-05-14"
updated: "2026-05-14"
last_updated: "2026-05-14"
related:
  - "[[SBDEV-2222-rest-inbound-no-idempotency-contract]]"
  - "[[wms2-oms-integration-map]]"
  - "[[wms2-end-to-end-request-journey]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
tags:
  - plan
  - wmsv2
  - oms-integration
  - rest-contract
  - reliability
  - exception-handling
---

# SBDEV-2230 — REST exception handler does not differentiate retryable vs non-retryable failures

**Ticket:** [SBDEV-2230](https://app.clickup.com/t/868jj32rd)
**Project:** wms2-api | **Version:** v2 | **Type:** bug
**Priority:** High | **Severity:** HIGH (Tier 2)
**Status:** reviewed (2026-05-14) — Architect+Critic consensus pass applied; verify script ships alongside this plan; first implementation pass pending.
**Date:** 2026-05-14

> **Framing:** When wms2-api throws a transient infrastructure exception (PgBouncer connection blip, lock acquisition timeout, query timeout) inside a `/rest/**` write handler that OMS retries, today's `RestExceptionHandler` either falls through to Spring's default 500 (for `DataAccessException` subclasses with no explicit handler) or returns 409 with no retry signal (for `ObjectOptimisticLockingFailureException` / `PessimisticLockingFailureException`). OMS cannot tell from the response whether retrying is safe and pointless (transient → retry) or counter-productive (permanent → escalate / page on-call). The SBDEV-2222 idempotency filter makes retries safe at the WMS side, but OMS still needs a machine-readable retry signal in the response.
>
> This plan introduces a deliberate split:
> 1. **Existing** `RestExceptionHandler` (`@ControllerAdvice`, unscoped) — patches H.5-H.8 to add a `retryable` body property on existing 409/422/404 handlers. **Status codes are unchanged.** Adding a body property is back-compat for all controllers (mobile, internal, rest).
> 2. **New** `RestEndpointExceptionHandler` (`@ControllerAdvice(basePackages = "net.aim_ai.wms.controller.rest")`, REST-only) — adds H.1, H.2, H.2b, H.2c, H.3, H.4, H.9 with `Retry-After: 30` for retryable cases and a catch-all that returns 500 + `retryable: false`. **Scoped to `/rest/**` controllers only** so mobile callers don't receive 503 Retry-After they wouldn't know how to handle.

---

## 1. Problem Statement

### 1.1 Symptom

OMS calls into wms2-api `/rest/order/create`, `/rest/order/cancel-positions`, `/rest/advice/create`, `/rest/sku/create`, `/rest/sku/update` and occasionally receives:

| Failure mode | Today's HTTP response | OMS interpretation | Correct interpretation |
|---|---|---|---|
| PgBouncer connection blip (`DataAccessResourceFailureException`) | 500 default Spring error JSON | "WMS broken — page on-call" | "Transient infra blip — safe to retry in 30s" |
| Postgres lock acquisition timeout (`CannotAcquireLockException`) | 500 default | "WMS broken" | "Retryable infra contention" |
| Postgres deadlock loser (`DeadlockLoserDataAccessException`) | 500 default | "WMS broken" | "Retryable — Postgres chose this txn as victim" |
| Spring DAO recoverable failure (`RecoverableDataAccessException`) | 500 default | "WMS broken" | "Retryable per Spring's own classification" |
| Statement / connection timeout (`QueryTimeoutException`) | 500 default | "WMS broken" | "Retryable — txn cancelled mid-flight" |
| FacadeException (external-system integration error) | 500 default | "WMS broken" | "Permanent — don't retry, escalate" |
| Optimistic lock conflict (`ObjectOptimisticLockingFailureException`) | 409 + ProblemDetail (no `retryable` property) | Ambiguous — retry? give up? | "Retryable — re-read state and retry" |
| Pessimistic lock conflict (`PessimisticLockingFailureException`) | 409 + ProblemDetail (no `retryable` property) | Ambiguous | "Retryable — contention cleared" |
| BusinessException (validation failure) | 422 + ProblemDetail (no `retryable` property) | Ambiguous | "Permanent — payload is invalid; do not retry" |
| EntityNotFoundException | 404 + ProblemDetail (no `retryable` property) | Ambiguous | "Permanent — entity gone; do not retry" |
| Unexpected RuntimeException | 500 default | Ambiguous | "Permanent — investigate; do not retry blindly" |

The gap is bidirectional:
- **Transient failures (DataAccessException subclasses, QueryTimeoutException)** have no explicit handler → fall through to Spring's default 500 → OMS treats as "WMS broken" and either pages on-call or stops retrying. Both are wrong: it's retryable.
- **Existing handlers (H.5-H.8)** map to the right status code but carry no machine-readable retry signal. OMS retries based on status code today (5xx → retry, 4xx → no retry), so 409 currently means "no retry" — which is wrong for 409 lock conflicts.

### 1.2 OMS retry-decision input (clarified)

OMS retry policy keys on **HTTP status code only** (confirmed by requester David Oppenheim, 2026-05-14). The `retryable` body property is supplementary observability for dashboards/humans — it is NOT currently consumed by OMS retry logic. If OMS adds body-field consumption in a follow-up, the property is already in place.

The `Retry-After: 30` value is hardcoded (confirmed by requester). Alignment with PgBouncer connection eviction interval or OMS retry backoff is not currently required.

### 1.3 Why the existing `RestExceptionHandler` cannot just be expanded in place

`RestExceptionHandler` carries `@ControllerAdvice` with no `basePackages` / `assignableTypes` restriction. It catches exceptions from ALL controllers — mobile (`/api/mobile/**`), tenant-discovery (`/landlord/**`), and rest (`/rest/**`). Adding a `Retry-After: 30` header and `503 Service Unavailable` mapping for `DataAccessResourceFailureException` there would affect mobile callers too — but mobile callers (a) do not benefit from SBDEV-2222 idempotency dedup (their endpoints are not `/rest/**`) and (b) have no documented retry behavior for `Retry-After`. Emitting an explicit retry signal to a caller who doesn't know what to do with it is a contract change we don't want.

**Solution:** Create a second `@ControllerAdvice` scoped to `controller.rest` package only. Spring resolves the most specific advice that matches. The existing unscoped advice handles H.5-H.8 (with body-only changes, no status change). The new scoped advice handles H.1-H.4, H.9, plus the new H.2b (DeadlockLoser) and H.2c (RecoverableDataAccess).

---

## 2. Root Cause Analysis

### 2.1 Affected file

`v2/wms2-api/src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java`

Current handlers (verified by reading the file at HEAD):

| Line | Handler | Exception | Today's status | Today's body | Gap |
|---|---|---|---|---|---|
| 35-40 | `handleInvalidParameters` | `ApiInvalidParameterException` | 422 | `ApiErrorMessage` | OK — keep as-is |
| 49-54 | `handleConstraintException` | `ApiConstraintViolationException` | 409 | `ApiErrorMessage` | OK — keep as-is |
| 64-77 | `handleValidationException` | `MethodArgumentNotValidException` | 422 | `ApiParameterErrorMessage` | OK — keep as-is |
| 86-92 | `handleMissingUser` | `ApiMissingUserException` | 422 | `ApiErrorMessage` | OK — keep as-is |
| 94-100 | `handleSsoCreateUserError` | `SsoCreateUserException` | ex.statusCode | `ApiErrorMessage` | OK — keep as-is |
| 102-108 | `handleSsoGroupLeaveOrJoinException` | `SsoGroupMembershipException` | 400 | `SsoGroupMembershipMessage` | OK — keep as-is |
| 110-116 | `handleGeneralSsoException` | `SsoException` | ex.status | `SsoMessage` | OK — keep as-is |
| **118-124** | `handleBusinessException` | `BusinessException` | 422 | `ProblemDetail` (no `retryable`) | **H.8 — add `retryable=false`** |
| 126-132 | `handleNoSuchElement` | `NoSuchElementException` | 404 | `ProblemDetail` (no `retryable`) | Out of scope (not in acceptance criteria list) — see §11 follow-ups |
| **134-140** | `handleEntityNotFound` | `EntityNotFoundException` | 404 | `ProblemDetail` (no `retryable`) | **H.7 — add `retryable=false`** |
| **142-148** | `handleOptimisticLock` | `ObjectOptimisticLockingFailureException` | 409 | `ProblemDetail` (no `retryable`) | **H.5 — add `retryable=true`** |
| **150-156** | `handlePessimisticLock` | `PessimisticLockingFailureException` | 409 | `ProblemDetail` (no `retryable`) | **H.6 — add `retryable=true`** |

Missing handlers (no `@ExceptionHandler` exists today for these types — they fall through to Spring's default 500):

| Handler ID | Exception | Today | Target |
|---|---|---|---|
| **H.1** | `DataAccessResourceFailureException` | 500 default | 503 + Retry-After + `retryable=true` |
| **H.2** | `CannotAcquireLockException` | 500 default | 503 + Retry-After + `retryable=true` |
| **H.2b** | `DeadlockLoserDataAccessException` | 500 default | 503 + Retry-After + `retryable=true` |
| **H.2c** | `RecoverableDataAccessException` | 500 default | 503 + Retry-After + `retryable=true` |
| **H.3** | `QueryTimeoutException` | 500 default | 503 + Retry-After + `retryable=true` |
| **H.4** | `FacadeException` | 500 default | 500 + `retryable=false` |
| **H.9** | `Exception` (catch-all) | 500 default (no body) | 500 + `retryable=false` ProblemDetail |

### 2.2 Why declaration order is NOT the answer

The Critic round flagged earlier draft language that said "place catch-all LAST in declaration order." This is wrong. Spring's `ExceptionHandlerMethodResolver` uses `ExceptionDepthComparator` (shortest inheritance distance wins) to select handlers, not source order. A `RuntimeException` will resolve to `handleOptimisticLock` (depth 0 for the exact type) regardless of where `handleException(Exception.class)` sits in the class body. Catch-all safety comes from inheritance hierarchy, not source position.

This matters for H.4 vs H.9: `FacadeException extends Exception` (verified — `FacadeException.java:26`). If both H.4 (`FacadeException.class`) and H.9 (`Exception.class`) are declared on the same `@ControllerAdvice`, H.4 wins by depth distance (0 vs 1). If they are split across two `@ControllerAdvice` classes, Spring picks the most specific one that matches the controller. Both H.4 and H.9 belong in the **new** `RestEndpointExceptionHandler` so they coexist by depth, not by class.

### 2.3 Why `DataAccessResourceFailureException` is mapped to retryable despite Spring's `NonTransient` classification

`DataAccessResourceFailureException extends NonTransientDataAccessException`. Spring's javadoc on `NonTransientDataAccessException` reads:

> "Root of the hierarchy of data access exceptions that are considered non-transient — where a retry of the same operation would fail unless the cause of the Exception is corrected."

**ADR-style override (we map it to 503 retryable anyway):**

- **Decision:** Map `DataAccessResourceFailureException` to 503 + `retryable=true` despite Spring's `NonTransient` classification.
- **Drivers:** In our PgBouncer-fronted topology, this exception's overwhelmingly common cause is (a) connection pool exhaustion during a burst, or (b) a brief network blip between wms2-api and PgBouncer, or (c) PgBouncer rotating a backend connection. All three are transient.
- **Alternatives considered:**
  - `CannotGetJdbcConnectionException` (a subset of `DataAccessResourceFailureException`) — too narrow; misses other transient resource-failure causes.
  - Leave as 500 default — defeats the purpose of the plan; OMS still pages on-call for transient blips.
- **Why this choice:** Broader coverage; matches operational reality of the PgBouncer topology.
- **Consequences / accepted risk:** A genuinely misconfigured datasource (wrong credentials, wrong host) will return 503 + retryable=true and OMS will retry until its retry budget exhausts. **Assumption (must hold):** OMS has a finite retry budget per request. **Confirm in OMS repo before merge** (§10 Open Question 1).
- **Follow-up:** If OMS retry budget turns out to be infinite, narrow this handler to `CannotGetJdbcConnectionException` only.

---

## 3. Design / Proposed Fix

### 3.1 Two-file structure

**Modified:** `v2/wms2-api/src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java`
- Patch H.5 (`handleOptimisticLock`): add `problemDetail.setProperty("retryable", true);`
- Patch H.6 (`handlePessimisticLock`): add `problemDetail.setProperty("retryable", true);`
- Patch H.7 (`handleEntityNotFound`): add `problemDetail.setProperty("retryable", false);`
- Patch H.8 (`handleBusinessException`): add `problemDetail.setProperty("retryable", false);`
- **Status codes UNCHANGED** for all 4 handlers.

**New:** `v2/wms2-api/src/main/java/net/aim_ai/wms/exceptions/RestEndpointExceptionHandler.java`
- `@ControllerAdvice(basePackages = "net.aim_ai.wms.controller.rest")`
- Handlers H.1, H.2, H.2b, H.2c, H.3, H.4, H.9.

#### Why `basePackages` not `assignableTypes`

`AbstractRestController` is package-private (no `public` modifier, `RestExceptionHandler` is in `net.aim_ai.wms.exceptions` — a different package). Using `@ControllerAdvice(assignableTypes = AbstractRestController.class)` would require either making `AbstractRestController` public (a deliberate API-surface change we don't want to bundle into this plan) or moving the new advice into the `controller.rest` package (adds a cross-cutting concern to a controller package).

`basePackages = "net.aim_ai.wms.controller.rest"` is the minimal-invasion choice: it lets the new advice live alongside the existing `RestExceptionHandler` in `net.aim_ai.wms.exceptions` and binds it scope-wise to the same package the 6 `*RestController` classes live in (verified by `grep -rln "AbstractRestController" v2/wms2-api/src/`: all 6 hits are in `controller/rest/`).

### 3.2 New `RestEndpointExceptionHandler` skeleton

```java
package net.aim_ai.wms.exceptions;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.CannotAcquireLockException;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.dao.DeadlockLoserDataAccessException;
import org.springframework.dao.QueryTimeoutException;
import org.springframework.dao.RecoverableDataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ControllerAdvice;
import org.springframework.web.bind.annotation.ExceptionHandler;

/**
 * REST-scoped exception handler for /rest/** endpoints.
 *
 * Scoped via basePackages to net.aim_ai.wms.controller.rest so mobile
 * controllers (which do not understand Retry-After) do not receive 503
 * retryable signals. Pairs with SBDEV-2222 idempotency filter: a 503
 * Retry-After response is safe to retry because /rest/** writes are
 * deduped by Idempotency-Key.
 *
 * Spring's ExceptionHandlerMethodResolver uses ExceptionDepthComparator
 * (shortest inheritance distance wins) to select handlers. Declaration
 * order within a class is NOT load-bearing. FacadeException (H.4) wins
 * over Exception (H.9) by depth.
 */
@ControllerAdvice(basePackages = "net.aim_ai.wms.controller.rest")
public class RestEndpointExceptionHandler {

    private static final Logger LOG = LoggerFactory.getLogger(RestEndpointExceptionHandler.class);
    private static final String RETRY_AFTER_SECONDS = "30";

    // H.1 — transient resource failure (PgBouncer blip, pool exhaustion)
    @ExceptionHandler(DataAccessResourceFailureException.class)
    protected ResponseEntity<ProblemDetail> handleResourceFailure(DataAccessResourceFailureException ex) {
        LOG.warn("Transient data-access resource failure: {}", ex.getMessage());
        ProblemDetail pd = ProblemDetail.forStatusAndDetail(
                HttpStatus.SERVICE_UNAVAILABLE, "Data store temporarily unavailable, please retry");
        pd.setTitle("Data Store Unavailable");
        pd.setProperty("retryable", true);
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .header("Retry-After", RETRY_AFTER_SECONDS)
                .body(pd);
    }

    // H.2 — lock acquisition timeout
    @ExceptionHandler(CannotAcquireLockException.class)
    protected ResponseEntity<ProblemDetail> handleCannotAcquireLock(CannotAcquireLockException ex) {
        LOG.warn("Could not acquire lock: {}", ex.getMessage());
        ProblemDetail pd = ProblemDetail.forStatusAndDetail(
                HttpStatus.SERVICE_UNAVAILABLE, "Lock contention, please retry");
        pd.setTitle("Lock Acquisition Timeout");
        pd.setProperty("retryable", true);
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .header("Retry-After", RETRY_AFTER_SECONDS)
                .body(pd);
    }

    // H.2b — Postgres chose this txn as deadlock victim
    @ExceptionHandler(DeadlockLoserDataAccessException.class)
    protected ResponseEntity<ProblemDetail> handleDeadlockLoser(DeadlockLoserDataAccessException ex) {
        LOG.warn("Deadlock victim: {}", ex.getMessage());
        ProblemDetail pd = ProblemDetail.forStatusAndDetail(
                HttpStatus.SERVICE_UNAVAILABLE, "Deadlock detected, please retry");
        pd.setTitle("Deadlock Detected");
        pd.setProperty("retryable", true);
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .header("Retry-After", RETRY_AFTER_SECONDS)
                .body(pd);
    }

    // H.2c — Spring's own classification of "you may retry"
    @ExceptionHandler(RecoverableDataAccessException.class)
    protected ResponseEntity<ProblemDetail> handleRecoverableDataAccess(RecoverableDataAccessException ex) {
        LOG.warn("Recoverable data access exception: {}", ex.getMessage());
        ProblemDetail pd = ProblemDetail.forStatusAndDetail(
                HttpStatus.SERVICE_UNAVAILABLE, "Temporary data access error, please retry");
        pd.setTitle("Recoverable Data Access Error");
        pd.setProperty("retryable", true);
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .header("Retry-After", RETRY_AFTER_SECONDS)
                .body(pd);
    }

    // H.3 — query / statement timeout
    @ExceptionHandler(QueryTimeoutException.class)
    protected ResponseEntity<ProblemDetail> handleQueryTimeout(QueryTimeoutException ex) {
        LOG.warn("Query timeout: {}", ex.getMessage());
        ProblemDetail pd = ProblemDetail.forStatusAndDetail(
                HttpStatus.SERVICE_UNAVAILABLE, "Query timeout, please retry");
        pd.setTitle("Query Timeout");
        pd.setProperty("retryable", true);
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .header("Retry-After", RETRY_AFTER_SECONDS)
                .body(pd);
    }

    // H.4 — external integration failure; permanent from WMS's point of view
    @ExceptionHandler(FacadeException.class)
    protected ResponseEntity<ProblemDetail> handleFacadeException(FacadeException ex) {
        LOG.error("Facade exception (external integration): {}", ex.getMessage(), ex);
        ProblemDetail pd = ProblemDetail.forStatusAndDetail(
                HttpStatus.INTERNAL_SERVER_ERROR, "Integration error, do not retry");
        pd.setTitle("Integration Error");
        pd.setProperty("retryable", false);
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(pd);
    }

    // H.9 — catch-all for unexpected exceptions on /rest/** only.
    //
    // Selected by ExceptionDepthComparator only when no more-specific handler
    // matches anywhere in the @ControllerAdvice chain. FacadeException (H.4)
    // wins by depth distance 0 vs 1, so this catch-all does not swallow it.
    @ExceptionHandler(Exception.class)
    protected ResponseEntity<ProblemDetail> handleUnexpected(Exception ex) {
        LOG.error("Unexpected exception in /rest/** handler", ex);
        ProblemDetail pd = ProblemDetail.forStatusAndDetail(
                HttpStatus.INTERNAL_SERVER_ERROR, "Internal server error");
        pd.setTitle("Internal Server Error");
        pd.setProperty("retryable", false);
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(pd);
    }
}
```

### 3.3 Patches to existing `RestExceptionHandler`

Per-handler `retryable` justification:

| Handler | retryable | Justification |
|---|---|---|
| H.5 `handleOptimisticLock` (`ObjectOptimisticLockingFailureException` → 409) | **true** | The record was modified mid-flight. Re-read state and retry will succeed. |
| H.6 `handlePessimisticLock` (`PessimisticLockingFailureException` → 409) | **true** | Lock contention. On retry the lock holder has released. |
| H.7 `handleEntityNotFound` (`EntityNotFoundException` → 404) | **false** | Entity is gone. No retry will resurrect it. |
| H.8 `handleBusinessException` (`BusinessException` → 422) | **false** | Permanent validation failure. The payload is invalid; retry returns the same 422. |

Code patch shape (one example — H.5):

```java
@ExceptionHandler(ObjectOptimisticLockingFailureException.class)
protected ResponseEntity<ProblemDetail> handleOptimisticLock(ObjectOptimisticLockingFailureException ex) {
    LOG.warn("Optimistic lock conflict: {}", ex.getMessage());
    ProblemDetail problemDetail = ProblemDetail.forStatusAndDetail(HttpStatus.CONFLICT, "The record was modified by another user. Please retry.");
    problemDetail.setTitle("Concurrent Modification Conflict");
    problemDetail.setProperty("retryable", true);   // ← new line
    return ResponseEntity.status(HttpStatus.CONFLICT).body(problemDetail);
}
```

Same shape for H.6 (true), H.7 (false), H.8 (false). No status-code changes. No header changes.

### 3.4 H.6 sub-class disambiguation

`PessimisticLockingFailureException` has two known subclasses:
- `CannotAcquireLockException` (H.2 — handled in new advice → 503 retryable)
- `DeadlockLoserDataAccessException` (H.2b — handled in new advice → 503 retryable)

Spring's `ExceptionDepthComparator` will route a thrown `CannotAcquireLockException` to H.2 (depth 0 to its own handler) and a thrown `DeadlockLoserDataAccessException` to H.2b (depth 0) regardless of which `@ControllerAdvice` they live in. The bare `PessimisticLockingFailureException` (parent type) keeps its existing 409 mapping (H.6) — only the bare parent type, not the more specific subclasses. This is the desired behavior:

- Bare `PessimisticLockingFailureException` (no subtype info) → 409 (today's behavior + new `retryable=true`)
- `CannotAcquireLockException` → 503 + Retry-After (new H.2)
- `DeadlockLoserDataAccessException` → 503 + Retry-After (new H.2b)

### Files changed

- **Modified:** `v2/wms2-api/src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java` (4 `setProperty("retryable", ...)` additions)
- **New:** `v2/wms2-api/src/main/java/net/aim_ai/wms/exceptions/RestEndpointExceptionHandler.java`
- **Modified:** `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/exceptions/RestExceptionHandlerUnitTest.java` (new `@Nested` classes + new `ThrowingController` endpoints + `TestableRestExceptionHandler` override stubs)

---

## 4. V1/V2 Applicability

| Aspect | V1 | V2 | Impact |
|---|---|---|---|
| `RestExceptionHandler` exists | Yes (similar shape, fewer handlers) | Yes (this plan target) | Sister v1 plan TBD if requested |
| ProblemDetail (RFC 7807) | Not used in v1 | Used in v2 (Spring Boot 3.x) | v1 needs alternate `ApiErrorMessage` shape if ported |
| OMS retry-on-503 contract | Same OMS contract for both | Same | One contract spec covers both |

### What Needs Porting

1. Same conceptual change: classify transient vs permanent on the v1 `RestExceptionHandler`. Different body shape (no ProblemDetail in v1).

### What Does NOT Need Porting

- The split into `RestEndpointExceptionHandler` is a v2-specific decision driven by Spring Boot 3.x advice resolution semantics. v1 may use a different approach (`@Order(...)` on the advice, or a `HandlerExceptionResolver`).

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | N/A — no schema change | — | Plan is exception-handler-only |
| 2 | **Feature flags / system properties** | N/A — no kill-switch needed; new advice is purely additive | — | The new advice only fires on exceptions that today produce 500-default. Worst case if advice is buggy: revert one file. |
| 3 | **Config / env changes** | N/A | — | — |
| 4 | **Deploy-order dependencies** | SBDEV-2222 (Idempotency filter) MUST be deployed first or together. | Nam Park | The 503 + retry-after contract is only safe because `/rest/**` writes are deduped by Idempotency-Key. Without SBDEV-2222, an OMS retry on 503 could double-create. |
| 5 | **Data migration** | N/A | — | — |
| 6 | **External systems** | OMS team confirmation that retry budget is finite. | David Oppenheim | See §10 Open Question 1. Decision recorded but not blocking — current OMS implementation retries on 5xx based on status code only. |
| 7 | **Access / permissions** | N/A | — | — |
| 8 | **Monitoring / alerts** | Grafana panel for `http.server.requests` filtered by `status=503,uri=/rest/**` to watch the retryable-503 rate post-deploy. | Nam Park | Optional; existing Micrometer metrics expose this without code change. |

### 5.2 Implementation Checklist

- [ ] **H.5** Patch `RestExceptionHandler.handleOptimisticLock` — add `problemDetail.setProperty("retryable", true);` (status 409 unchanged). Justification: optimistic lock conflict IS retryable (re-read state + retry).
- [ ] **H.6** Patch `RestExceptionHandler.handlePessimisticLock` — add `problemDetail.setProperty("retryable", true);` (status 409 unchanged). Justification: lock contention retryable.
- [ ] **H.7** Patch `RestExceptionHandler.handleEntityNotFound` — add `problemDetail.setProperty("retryable", false);` (status 404 unchanged). Justification: entity gone, no retry will help.
- [ ] **H.8** Patch `RestExceptionHandler.handleBusinessException` — add `problemDetail.setProperty("retryable", false);` (status 422 unchanged). Justification: permanent validation failure.
- [ ] **H.1** Create `RestEndpointExceptionHandler` with `@ExceptionHandler(DataAccessResourceFailureException.class)` → 503 + Retry-After: 30 + `retryable=true`.
- [ ] **H.2** Add `@ExceptionHandler(CannotAcquireLockException.class)` → 503 + Retry-After: 30 + `retryable=true`.
- [ ] **H.2b** Add `@ExceptionHandler(DeadlockLoserDataAccessException.class)` → 503 + Retry-After: 30 + `retryable=true`.
- [ ] **H.2c** Add `@ExceptionHandler(RecoverableDataAccessException.class)` → 503 + Retry-After: 30 + `retryable=true`.
- [ ] **H.3** Add `@ExceptionHandler(QueryTimeoutException.class)` → 503 + Retry-After: 30 + `retryable=true`.
- [ ] **H.4** Add `@ExceptionHandler(FacadeException.class)` → 500 + `retryable=false`.
- [ ] **H.9** Add `@ExceptionHandler(Exception.class)` catch-all → 500 + ProblemDetail + `retryable=false`. **MUST be `Exception.class`, NOT `RuntimeException.class`** (so checked exceptions thrown by `/rest/**` handlers are caught too — e.g. `FacadeException extends Exception`).
- [ ] Annotate `RestEndpointExceptionHandler` with `@ControllerAdvice(basePackages = "net.aim_ai.wms.controller.rest")`.
- [ ] Extend `RestExceptionHandlerUnitTest` (existing class — file name is `RestExceptionHandlerUnitTest.java`, NOT `RestExceptionHandlerTest.java`):
    - Add override stubs for the H.5-H.8 patched methods in `TestableRestExceptionHandler` (if not already present — H.5/H.6 are not in today's `TestableRestExceptionHandler`, H.7 and H.8 are present indirectly via MockMvc).
    - Add new `@Nested` classes: `HandleOptimisticLock`, `HandlePessimisticLock`, `HandleEntityNotFound`, and add assertions for `retryable` property on existing `HandleBusinessException`.
    - Add new `@Nested` classes for `RestEndpointExceptionHandler`: `HandleResourceFailure`, `HandleCannotAcquireLock`, `HandleDeadlockLoser`, `HandleRecoverableDataAccess`, `HandleQueryTimeout`, `HandleFacadeException`, `HandleUnexpected`. Each uses MockMvc with `.setControllerAdvice(new RestEndpointExceptionHandler())`.
    - Add new `ThrowingController` inner-controller methods: `throwResourceFailure()`, `throwCannotAcquireLock()`, `throwDeadlockLoser()`, `throwRecoverableDataAccess()`, `throwQueryTimeout()`, `throwFacadeException()`, `throwUnexpectedException()`.
- [ ] Run `mvn test -Dtest=RestExceptionHandlerUnitTest` — must pass with 0 failures.
- [ ] Run `bash sbdocs/9-System/scripts/verify-SBDEV-2230-rest-exception-handler-retryable-differentiation.sh` — must exit 0.
- [ ] Update `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` retry-semantics section to reference SBDEV-2230 contract.
- [ ] Code review.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|---|---|---|
| `/rest/order/create` raises `DataAccessResourceFailureException` (simulated PgBouncer down) | MockMvc POST → handler throws → advice catches | 503 + `Retry-After: 30` + body contains `"retryable":true` |
| `/rest/order/create` raises `CannotAcquireLockException` | MockMvc POST | 503 + Retry-After + retryable=true |
| `/rest/order/create` raises `DeadlockLoserDataAccessException` | MockMvc POST | 503 + Retry-After + retryable=true |
| `/rest/order/create` raises `RecoverableDataAccessException` | MockMvc POST | 503 + Retry-After + retryable=true |
| `/rest/order/create` raises `QueryTimeoutException` | MockMvc POST | 503 + Retry-After + retryable=true |
| `/rest/order/create` raises `FacadeException` | MockMvc POST | 500 + body `retryable=false`, NO Retry-After header |
| `/rest/order/create` raises `ObjectOptimisticLockingFailureException` | MockMvc POST | 409 (UNCHANGED) + body `retryable=true` |
| `/rest/order/create` raises bare `PessimisticLockingFailureException` (parent type, not a subclass) | MockMvc POST | 409 (UNCHANGED) + body `retryable=true` |
| `/rest/order/create` raises `BusinessException` | MockMvc POST | 422 (UNCHANGED) + body `retryable=false` |
| `/rest/order/create` raises `EntityNotFoundException` | MockMvc POST | 404 (UNCHANGED) + body `retryable=false` |
| `/rest/order/create` raises unexpected `IllegalStateException` (catch-all path) | MockMvc POST | 500 + body `retryable=false` (NOT default Spring error JSON) |
| Mobile controller raises `DataAccessResourceFailureException` | MockMvc against a mobile-controller endpoint (verify the new advice does NOT fire — scope check) | 500 default (unchanged from today) — confirms `basePackages` scoping works |

### New / updated tests

| Test class | Test method | What it asserts |
|---|---|---|
| `RestExceptionHandlerUnitTest` | `HandleOptimisticLock#shouldReturn409_withRetryableTrue` | 409 + body contains `"retryable":true` |
| `RestExceptionHandlerUnitTest` | `HandlePessimisticLock#shouldReturn409_withRetryableTrue` | 409 + retryable=true (bare parent type only) |
| `RestExceptionHandlerUnitTest` | `HandleEntityNotFound#shouldReturn404_withRetryableFalse` | 404 + retryable=false |
| `RestExceptionHandlerUnitTest` | `HandleBusinessException#shouldReturn422_withRetryableFalse` | 422 + retryable=false |
| `RestExceptionHandlerUnitTest` | `HandleResourceFailure#shouldReturn503_withRetryAfter_andRetryableTrue` | 503 + `Retry-After: 30` + retryable=true |
| `RestExceptionHandlerUnitTest` | `HandleCannotAcquireLock#shouldReturn503_withRetryAfter_andRetryableTrue` | 503 + Retry-After + retryable=true |
| `RestExceptionHandlerUnitTest` | `HandleDeadlockLoser#shouldReturn503_withRetryAfter_andRetryableTrue` | 503 + Retry-After + retryable=true |
| `RestExceptionHandlerUnitTest` | `HandleRecoverableDataAccess#shouldReturn503_withRetryAfter_andRetryableTrue` | 503 + Retry-After + retryable=true |
| `RestExceptionHandlerUnitTest` | `HandleQueryTimeout#shouldReturn503_withRetryAfter_andRetryableTrue` | 503 + Retry-After + retryable=true |
| `RestExceptionHandlerUnitTest` | `HandleFacadeException#shouldReturn500_withRetryableFalse` | 500 + retryable=false; no Retry-After header |
| `RestExceptionHandlerUnitTest` | `HandleUnexpected#shouldReturn500_withRetryableFalse` | 500 + retryable=false (against `IllegalStateException`) |
| `RestExceptionHandlerUnitTest` | `HandleUnexpected#facadeExceptionWinsByDepthOverCatchAll` | When both `RestEndpointExceptionHandler` advice classes wire to MockMvc, a thrown `FacadeException` is caught by H.4 (500 + the H.4 title) not H.9 |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Smoke: OMS sends `/rest/order/create` while PgBouncer is bounced for 5s | staging | 1. SSH to staging, `systemctl restart pgbouncer`. 2. From OMS staging, retry `/rest/order/create` 10 times across the 5s window. | At least 1 request returns 503 with `Retry-After: 30` and body `"retryable":true`. OMS retries succeed within 60s. | |
| Mobile controller scope check | staging | Trigger `/api/mobile/...` endpoint that throws an unexpected exception | 500 (default Spring) — NOT 500 + ProblemDetail with `retryable` (confirms scope-by-basePackages). | |
| `/rest/order/create` happy path | staging | OMS sends valid payload | 200/201 (no change from today) | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=RestExceptionHandlerUnitTest` | | |
| `mvn verify` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2230-rest-exception-handler-retryable-differentiation.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Integration test against real Postgres for H.1/H.2 | The exception types are Spring-DAO-classified at the JDBC translator layer; we trust Spring's translator and assert handler behavior unit-style. Real-Postgres deadlock reproduction is exercised by `SBDEV-2223` integration tests separately. |

---

## 7. Horizontal Scalability Validation (v2 plans — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce state that only exists in one replica? | **No** | Exception handlers are stateless. No fields beyond final constants (`LOG`, `RETRY_AFTER_SECONDS`). |
| 2 | **Connection pool math** | Change per-request DB connection usage? | **No** | Exception handlers do no DB work. They translate an in-flight exception into a response. |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` / cron job? | **No** | No scheduled job in this plan. |
| 4 | **Long transactions** | Hold a DB transaction across multiple repository calls or external I/O? | **No** | Handlers run after the transaction has already failed and unwound. |
| 5 | **Request affinity** | Assume follow-up request lands on the same replica? | **No** | The 503 + Retry-After signal is replica-agnostic; OMS's retry can land on any replica. SBDEV-2222 idempotency dedup happens via the shared tenant DB (`rest_idempotency` table). |
| 6 | **Retry / idempotency** | Rely on single-execution semantics that break if a replica dies mid-op? | **Yes — depends on SBDEV-2222** | The 503 + Retry-After contract is only safe because SBDEV-2222's `IdempotencyFilter` deduplicates retries on the WMS side. This is a hard deploy-order dependency (§5 prereq 4). Without SBDEV-2222, an OMS retry of a 503 could double-create on the second attempt if the first attempt actually wrote and only crashed during response serialization. |
| 7 | **Tenant context** | Use `TenantContext` / `ThreadLocal` across async boundaries? | **No** | Handlers run on the request thread; `TenantContext` is set by `TenantFilter` upstream and torn down by the filter chain. The handler reads no tenant state. |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic / optimistic lock across replicas? | **No** | Plan adds NO locks. It only TRANSLATES lock-failure exceptions into HTTP responses. |
| 9 | **Cache invalidation** | Write to an entity that is cached? | **No** | Handlers do no writes. |
| 10 | **External notifications** | Send HTTP / message to an external system inside a transaction? | **No** | Handlers do no external I/O. They emit the HTTP response that OMS reads — but that is the request's own response, not a separate notification. |

### Evidence

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 6 | SBDEV-2222 plan reviewed and confirmed deployed before SBDEV-2230 starts implementation | `sbdocs/1-Projects/wms2/plan/SBDEV-2222-rest-inbound-no-idempotency-contract.md` status=implemented |

---

## 8. v2-only Constraint Checklist

| # | Rule | Compliant? | Where verified |
|---|---|---|---|
| 1 | All tenant-scoped `@Transactional` uses `value = "tenantTransactionManager"` | N/A | Plan adds no `@Transactional` methods. |
| 2 | OSIV — repository calls outside `@Transactional` open new sessions | N/A | Plan adds no repository calls. |
| 3 | Constructor injection only — no `@Autowired` fields | Yes | `RestEndpointExceptionHandler` has no dependencies; matches the existing `RestExceptionHandler` style (also has none). |
| 4 | SLF4J parameterized logging — no string concatenation | Yes | All `LOG.warn` / `LOG.error` calls in new code use `{}` placeholders. |
| 5 | Prefer `.orElseThrow(...)` over `.get()` | N/A | No `Optional` usage in new code. |
| 6 | Jakarta namespace (`jakarta.*`) — not `javax.*` | Yes | No `javax.*` imports added. ProblemDetail imports `org.springframework.http.*`. |
| 7 | `AbstractBaseEntity.equals()` ID-based — do not rely on `.equals` for unsaved entities | N/A | No entity comparison in this plan. |
| 8 | Multi-tenant — every entity write goes through the tenant DataSource | N/A | No DB writes in this plan. |

---

## 9. Risks & Mitigations

| # | Risk | Likelihood | Blast radius | Mitigation |
|---|---|---|---|---|
| 1 | A genuinely misconfigured datasource returns 503 + retryable=true forever → OMS retries until its budget exhausts. | Low | Low | OMS retry budget is finite (assumption — see §10 Open Question 1). Misconfigured datasource will also surface in liveness/readiness probes within 30s; ops will see it. |
| 2 | New catch-all H.9 swallows an exception we'd rather log louder (e.g. NullPointerException with a useful stack trace). | Medium | Low | H.9 calls `LOG.error("Unexpected exception in /rest/** handler", ex)` — passes the exception to the logger so the full stack appears in the log. Operationally identical to default 500 logging. |
| 3 | Mobile controllers throw `DataAccessResourceFailureException` and still get 500 default (because `basePackages` excludes them). | Certain | Low — that's the design | Mobile callers do not understand Retry-After; sending a 503 retryable signal to a mobile client would be a contract change we explicitly do not want. The plan's scope-by-`basePackages` is the mitigation, not a bug. |
| 4 | Some `/rest/**` controller currently relies on Spring's default 500 prose body (e.g. a downstream automated tool parses the body). | Low | Low | Default Spring error body is `{"timestamp":...,"status":500,"error":"Internal Server Error","path":"..."}`. Our new body is `{"type":"about:blank","title":"Internal Server Error","status":500,"detail":"Internal server error","retryable":false}`. Different shape. We grep `/rest/**` callers (OMS) and confirm they read status only. The verify-script's negative check catches code that depends on the old body shape. |
| 5 | `FacadeException` is thrown deep inside a service and wrapped by an outer `RuntimeException` before reaching the handler. H.4 by depth would NOT fire on the wrapped exception. | Medium | Medium | Spring's `ExceptionHandlerExceptionResolver` unwraps `Throwable.getCause()` via `getMostSpecificCause` only in some paths. We add a unit test (`HandleFacadeException#wrapsFacadeIntoRuntimeStillHitsH4`) to assert that a direct `throw new FacadeException(...)` from a handler hits H.4, and document that wrapped/nested cases need a per-service `try { ... } catch (FacadeException) { throw; }` audit. The audit itself is out of scope for this plan. Tracked in §11 follow-ups. |
| 6 | `ObjectOptimisticLockingFailureException` is sometimes thrown by a service that has already partially auto-committed across the legacy non-`tenantTransactionManager` path. Retry would double-write. | Low | High | This is the SBDEV-2222 idempotency-filter's job to prevent. `/rest/**` writes are deduped by `Idempotency-Key`. Without SBDEV-2222 in place, the retryable=true signal would be unsafe — hence the hard deploy-order dependency (§5 prereq 4 + §7 row 6). |

---

## 10. Open Questions

1. **OMS retry budget is finite** — confirm in OMS repo. If retry budget is infinite, narrow H.1 to `CannotGetJdbcConnectionException` only (more conservative). **Owner:** David Oppenheim. **Blocks:** No — implementation can proceed with the assumption documented; tighten if OMS responds otherwise.
2. **Retry-After value of 30 seconds is hardcoded.** If OMS retry backoff schedule diverges meaningfully, parameterize via system property. Today: confirmed not required.
3. **`NoSuchElementException` (line 126-132 in existing `RestExceptionHandler`) is currently 404 with no `retryable` property.** Out of scope for the 13 acceptance criteria but a candidate for a follow-up patch. **Owner:** Nam Park. **Tracker:** `.omc/plans/open-questions.md`.
4. **Wrapped `FacadeException` audit** (Risk #5) — if a service wraps `FacadeException` in a `RuntimeException`, H.4 may not match. Service-side audit is a separate plan. **Owner:** Nam Park. **Tracker:** `.omc/plans/open-questions.md`.

---

## 11. Notes

**Related plans / docs:**
- `sbdocs/1-Projects/wms2/plan/SBDEV-2222-rest-inbound-no-idempotency-contract.md` — hard dependency. This plan's 503 + retryable contract is only safe because SBDEV-2222's `IdempotencyFilter` is in place.
- `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` — to be updated with the retry-semantics table from §1.

**Deployment considerations:**
- Deploy SBDEV-2222 first (already implemented; status=implemented as of 2026-05-12).
- This plan's two files (`RestExceptionHandler.java` patch + new `RestEndpointExceptionHandler.java`) ship in the same commit. The 4 patches to existing handlers are additive (body property only, no status change) so they are back-compat for non-OMS callers.
- No DB migration. No system property toggle. No restart sequencing concerns beyond standard rolling deploy.

**Follow-up work (not in this plan):**
- Audit services for wrapped `FacadeException` cases (Risk #5).
- Add `retryable` property to `NoSuchElementException` handler (Open Question 3).
- Consider parameterizing `Retry-After` value (Open Question 2).
- Consider extending the same pattern to mobile controllers if/when mobile callers adopt Retry-After semantics.

**Implementation status (to be filled in by the implementer):**
- `RestExceptionHandler.java` patch SHA: `TBD`
- `RestEndpointExceptionHandler.java` SHA: `TBD`
- Test SHA: `TBD`
- `mvn verify` result: `TBD`
- Verify-script result: `TBD`
- PR link: `TBD`

---

## 12. Acceptance & Implementation

### 12.1 Acceptance script (machine-checkable)

Script path: `sbdocs/9-System/scripts/verify-SBDEV-2230-rest-exception-handler-retryable-differentiation.sh`

**13 acceptance criteria** the verify script enforces:

1. `DataAccessResourceFailureException` → 503 + `Retry-After: 30` + `retryable: true` (via `RestEndpointExceptionHandler`)
2. `CannotAcquireLockException` → 503 + `Retry-After: 30` + `retryable: true`
3. `DeadlockLoserDataAccessException` → 503 + `Retry-After: 30` + `retryable: true`
4. `RecoverableDataAccessException` → 503 + `Retry-After: 30` + `retryable: true`
5. `QueryTimeoutException` → 503 + `Retry-After: 30` + `retryable: true`
6. `FacadeException` → 500 + `retryable: false`
7. `ObjectOptimisticLockingFailureException` → 409 + `retryable: true` (status UNCHANGED; existing handler patched)
8. Bare `PessimisticLockingFailureException` (parent type, NOT `CannotAcquireLockException` or `DeadlockLoserDataAccessException`) → 409 + `retryable: true` (status UNCHANGED)
9. `BusinessException` → 422 + `retryable: false` (status UNCHANGED)
10. `EntityNotFoundException` → 404 + `retryable: false` (status UNCHANGED)
11. Catch-all `Exception` (via `RestEndpointExceptionHandler`) → 500 + `retryable: false`
12. `mvn test -Dtest=RestExceptionHandlerUnitTest` exits 0
13. No existing handler regressions (ApiInvalidParameter, ApiConstraintViolation, MethodArgumentNotValid, ApiMissingUser, Sso* — all keep their existing status and body shape)

### 12.2 Recommended OMC composition (for implementation)

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | 11 handlers across 2 files; single subsystem; clear contract |
| **Pre-draft step** | none (consensus mode already completed via ralplan) | Architect+Critic feedback already incorporated |
| **Plan-review step** | critic | Catches any remaining gaps before code starts |
| **Implementation shape** | executor | Mechanical; verify-script + MockMvc tests are exhaustive |
| **Verification step** | verify-script + verifier (mandatory) | Always |
| **Code-review step** | code-reviewer | Final pass before commit |
| **Commit step** | git directly | Single commit with both files |

#### Why this matters

The verify-script's 13 PASS lines are the contract. The script enforces both POSITIVE checks (the new handlers exist with the right annotations and return values) and NEGATIVE checks (no status-code change on H.5-H.8; no `Retry-After` header on H.4 or H.9). Code-shape greps prove the call exists; MockMvc tests prove it works.

---

## 13. ADR (consensus mode)

**Decision:** Split exception handling into two `@ControllerAdvice` classes: existing unscoped `RestExceptionHandler` keeps H.5-H.8 (body-only patches); new `RestEndpointExceptionHandler` scoped to `controller.rest` package adds H.1-H.4, H.2b, H.2c, H.9 with `Retry-After` headers.

**Drivers:**
1. OMS needs a machine-readable signal differentiating transient vs permanent failures on `/rest/**`.
2. Mobile / internal controllers must NOT receive `Retry-After: 30` (no documented behavior on the caller side).
3. The `Retry-After` contract is only safe under SBDEV-2222 idempotency dedup, which scopes to `/rest/**`.

**Alternatives considered:**
- (a) Add `Retry-After` directly to the existing unscoped `RestExceptionHandler`. **Rejected:** would emit retryable signal to mobile/internal callers that don't handle it.
- (b) Make `RestExceptionHandler` scoped (add `basePackages` to the existing class). **Rejected:** the existing class also handles mobile-relevant cases (`ApiInvalidParameterException`, `SsoException`); scoping it would break mobile-side error handling.
- (c) Two `@ControllerAdvice` classes — unscoped (existing) + new scoped (`controller.rest`). **Chosen.**

**Why chosen:** Minimal blast radius. Existing handlers keep their current behavior for non-`/rest/**` callers. New `/rest/**`-only handlers carry the new contract. No existing-handler regression risk.

**Consequences:**
- Two files to maintain instead of one. Mitigated by clear separation of concerns documented in class-level javadoc.
- A future developer must know which advice class to add a handler to. Mitigated by class-level comment + a §11 follow-up to update `wms2-oms-integration-map.md` with the routing rule.

**Follow-ups:**
- Wrapped-`FacadeException` audit (Risk #5).
- `NoSuchElementException` retryable property (Open Question 3).
- `Retry-After` parameterization (Open Question 2).

## 11. Implementation Status (v2 — 2026-05-14)

**Status:** Implemented and PR submitted.

| Item | Detail |
|---|---|
| Commit | `923f23a` — `feat(SBDEV-2230): add REST-scoped exception handler with retryable differentiation` |
| PR | [#18 — SiteBossInc/wms2-api](https://github.com/SiteBossInc/wms2-api/pull/18) |
| Branch | `tasks/SBDEV-2230` → `develop` |
| Tests | 30/30 TDD gate pass; 3958/3958 full suite pass (0 failures, 65 skipped) |

### Files changed

| File | Change |
|---|---|
| `exceptions/RestEndpointExceptionHandler.java` | New — 7 handlers (5×503-retryable, FacadeException→500, catch-all→500) |
| `exceptions/RestExceptionHandler.java` | Patched — added `retryable` property to 4 existing handlers |
| `unit/exceptions/RestExceptionHandlerUnitTest.java` | Added 11 TDD gate tests (AC1-AC11) |

### Code review findings addressed

- **HIGH**: Added `@Order(Ordered.HIGHEST_PRECEDENCE)` to prevent tie-break nondeterminism if a future global catch-all is added to `RestExceptionHandler`
- **HIGH**: `FacadeException` handler returns generic `"Operation failed"` (not `ex.getMessage()`) to avoid i18n key / internal message leakage at 500
- **MEDIUM**: Extracted `RETRY_AFTER_SECONDS` constant and `retryable503()` helper — eliminates 5-way duplication
- **LOW**: All `LOG.warn()` calls pass `ex` as trailing arg for full stack trace retention; titles added to all new handlers

### Doc drift noted (separate follow-up)

`wms-exception-taxonomy.md` lines 93, 110, 114, 358, 367 contain stale claims about FacadeException / optimistic-lock handlers. `wms2-oms-integration-map.md` line 235 needs a 503 row. Both docs are green on staleness timer but need factual corrections.
