---
ticket: SBDEV-3128
phase: 1 (wms2-api)
lane: impl-security-review
head: 7fb22890
base: origin/develop 8171c80a
reviewer: security-reviewer (read-only; git show / git diff only; no mvn)
date: 2026-11-02
verdict: APPROVE (no Critical / High / Medium; 4 Low, 3 Informational)
note: saved by the main session from the lane's returned text (lane had no Write tool)
---

# Security Review Report: SBDEV-3128 Phase 1

**Scope:** `git diff 8171c80a...7fb22890`, 27 files. Main-source: `LocationController`, `FixLocationAssignmentController`,
`FixLocationAssignmentService`, `LocationService`, `ViewDtoService`, `LocationRepository`, `FixLocationAssignmentRepository`,
three projections, `LocationBoundDefaultsResult`, `V2.2.45__location_default_fla_bounds.sql`. Context read:
`FunctionGuardInterceptor`, `WebConfig`, `RestConfiguration`, `RestExceptionHandler`, `RestEndpointFallbackExceptionHandler`,
`Sbdev3017TrancheGateContextTest`, `FunctionGuardArchTest`.
**Risk Level:** LOW — Critical 0, High 0, Medium 0, Low 4, Informational 3.

## Low

### L1. `updateBoundDefaults` has no magnitude or length limit on the decimals (A03/A04)
`LocationController.decimalOrNull` — `return value == null ? null : new BigDecimal(value.toString());` and
`validateDefaultBounds` — `if (lower.scale() > 4 || …)`.
Accepts any JSON value incl. a **string**. (1) Non-positive scale passes, so `"1E+999999999"` or a 20-digit integer
reaches Postgres and fails with `numeric field overflow` (the service mirrors the CHECK but not `numeric(17,4)`'s |x| < 10^13).
(2) Jackson caps numeric tokens at 1000 chars but strings at 20M; `new BigDecimal(String)` on multi-MB digit strings can tie a
worker thread (unmeasured). (3) Huge-exponent bind cost in pgjdbc unverified. No corruption (DB rejects, tx rolls back); error
text reaches client (L2).
**Fix:** accept only `Number`, cap `toString()` length (32), catch `NumberFormatException` (Double Infinity → `"Infinity"`),
and in the service reject `upper.abs() >= 10^13`. Unit rows: `"1E+20"`, a string value, `1e400`.

### L2. `updateBoundDefaults` returns raw exception messages, incl. SQL, to the client (A05)
`} catch (Exception e) { errors.add(getErrorMessage("Runtime Error", e.getMessage())); }` — any `DataAccessException`
returns 200 with SQL text (`could not execute statement [ERROR: numeric field overflow …] [update location set …]`); a CHECK
failure echoes the whole `location` row (`Failing row contains (...)`); a `ClassCastException` on `id` returns JVM text. Also
swallows `EntityNotFoundException` (404) / `ObjectOptimisticLockingFailureException` (409) into 200. Low (private API, caller
holds the function), but `catch (Exception)` widens it.
**Fix:** catch only `BusinessException` (and `ClassCastException | NullPointerException` → "id must be a number"); let the rest
reach the advice (Boot default 500, no message).

### L3. `resetBoundsToDefault` casts `id` outside the try block (A04)
`Long id = ((Number) reqMap.get("id")).longValue(); try {` — missing `id` → NPE, string → `ClassCastException`; no handler in
`RestExceptionHandler`, `RestEndpointFallbackExceptionHandler` scoped to `controller.rest` → Boot 500 (no message leaked) +
ERROR log per request. Sibling handlers likely same pattern.
**Fix:** `if (!(reqMap.get("id") instanceof Number n)) { …errors "id must be a number"…; return ResponseEntity.ok(errorMap); }`.

### L4. Raw request value logged before type-check (A09 log injection)
`LOG.debug("updateBoundDefaults id={}", reqMap.get("id"));` — CR/LF in a string id can forge log lines (DEBUG only,
authenticated caller). **Fix:** log after the cast, as `resetBoundsToDefault` does.

## Informational (no action required)
- **I1. Cross-screen gating by design.** A `WEB_UI_VIEW_STORAGE_LOCATION`-only user changes an INHERITED FLA's effective bounds via
  write-through (owned otherwise by `WEB_UI_VIEW_FIXED_ASSIGNMENT`) and fires `replenishmentMaintenanceTrigger`. Follows settled
  D1 + gate-on-screen rule. Record in the role matrix so grants are made knowingly. (PRD: 41/41/0 — nobody holds only one.)
- **I2. No principal in the audit trail.** `Principal` accepted but unused; native UPDATEs set only `modified`; DEBUG logs have no
  username. Same as sibling bound setters. Pre-existing pattern.
- **I3. Within-tenant client scoping.** No `clientService.callerScopeClient()` on either endpoint — nor on sibling
  `/v3/location/update`, `/v3/fixedAssignment/set*Bound`. IDOR surface equals the existing write surface. Nothing crosses tenants.

## Ruled out
1. **Gates enforced at runtime.** `FunctionGuardInterceptor.preHandle` reads the method annotation (`:236`) before the class fallback
   (`:264-266`), calls `accessService.checkAnyAccess` when either is non-null (`:280-290`); `GUARDED` consulted only when both null
   (`:269-271`). So the method-level gate on `LocationController.updateBoundDefaults` is enforced though the class is not in
   `GUARDED`. `FixLocationAssignmentController` class-level gate at `:31` covers `resetBoundsToDefault` (declared on that class).
   Interceptor is a broad `MappedInterceptor` (`WebConfig`).
2. **Gate test bites.** `Sbdev3017TrancheGateContextTest.everyTrancheRouteCarriesItsIntendedFunctions` walks live
   `RequestMappingHandlerMapping`; `resolve()` (`:878-885`) mirrors the interceptor order. Removing a gate → `UNGATED`; renaming →
   `ROUTE NOT DEPLOYED`; pin 232 → 234 (+2). Read, not mutation-run.
3. **No ungated write path.** All 5 new FLA repo methods and 4 new Location repo methods carry `@RestResource(exported = false)`; FLA
   repo un-exported wholesale (SBDEV-3183); `FunctionGuardArchTest` pins the 5 names. Columns unmapped (D8; no model diff, no
   `@JsonAnySetter`), so `/location/create`, `/update`, SDR DELETE cannot set them.
4. **SQL injection.** All new native queries use named binds; no request-input concatenation; probe has no parameters;
   `current_schema()` server-controlled. If `search_path` ever made it non-`public`, the probe reads false → fail-closed.
   `information_schema.columns` lists columns the role has privileges on; the app role owns these tables.
5. **Numeric edges.** NaN impossible (Jackson default). `1e400` → Double Infinity → `NumberFormatException` caught → `{errors}`
   (JVM text, L2). Negatives rejected (service + CHECK). Double `id` truncated by `longValue()` → same tenant only.
6. **No cross-tenant reach.** `id` resolves only in the routed tenant DataSource; `TenantFilter` + `MultiTenantJwtDecoder`; no
   tenant id read from body; no landlord access.
7. **D9 path.** Fixed `BusinessException` naming `V2.2.45` (trivial disclosure). Unguarded lists 42703 → Boot 500 without message.
8. **Migration.** `SET LOCAL lock_timeout = '5s'` (D4, V2.2.40 precedent); no GRANT/REVOKE/ALTER ROLE/OWNER TO/SECURITY DEFINER/
   search_path; `DO $$` CHECK guarded by `pg_constraint`; 42501 if not owner → rollback, tenant stays 2.2.44, D9 handles it;
   backfill casts only `^[+-]?[0-9]{1,18}$`.
9. **Logging.** ids/triples/counter at DEBUG; `ViewDtoService` WARN logs a sysprop value (admin config). No secrets/PII. (L4 aside.)
10. **Secrets.** None; only Testcontainers `withPassword("test")`.
11. **Dependencies.** No `pom.xml` change; no audit tool run (no mvn in lane).
12. **CSRF/CORS.** Unchanged; bearer-JWT JSON POSTs.

## Verdict
**APPROVE.** Fix L1–L4 this pass (address-Lows policy): L1+L2 together (~20 lines + 3 unit rows), then L3, then L4.
