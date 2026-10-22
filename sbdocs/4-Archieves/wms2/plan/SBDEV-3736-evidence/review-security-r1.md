---
ticket: SBDEV-3736
lane: security-review r1
head: 666fe51a
base: origin/develop (merge-base diff)
date: 2026-10-15
db: wsl-wineco-prd (read-only)
verdict: PASS-WITH-LOWS
counts: {high: 0, medium: 0, low: 3, info: 3}
---

# SBDEV-3736 — Security review, round 1 (returns audit endpoint)

**Scope:** `ReportController.returnsAudit` (+ inherited `/v3/dashboard/returnsAudit`), `AdvicepositionRepository.findReturnsAudit`,
`ReturnsAuditView`, `ViewDtoService.getReturnsAudit`, gate tests (`ReportReadGateUnitTest`, `Sbdev3017TrancheGateContextTest`).
I read the auto-finish changes in `ReceivingService` / `ReturnAdviceAutoReceiveService` only for logging and secrets.
**Risk level:** LOW. Nothing is exploitable. There are three hardening and test-gap items.

## Verified (no finding)

| Check | Evidence |
|---|---|
| Gate enforced on both routes | `FunctionGuardInterceptor.preHandle` reads `handlerMethod.getMethodAnnotation(RequiresFunction.class)` (:231). The interceptor finds a method-level annotation regardless of `GUARDED` membership; `GUARDED` matters only when no annotation exists (:265). The inherited dashboard handler resolves to the same `Method`. Both prefixes are pinned (`Sbdev3017TrancheGateContextTest` +2 rows, 229) and both return 403 through the real guard (`setupMockMvcWithGuard`, `denyEverything`). The repo convention is `@RequiresFunction`. `@PreAuthorize` is used only for `IS_SB_ADMIN`. |
| Exact function, no widening, no class-level collapse | `assertFunction` → `assertAnyOf` reads the **method's own** `getAnnotation(RequiresFunction.class)` (ReportReadGateUnitTest:452) and asserts an exact set. A wrong constant, a widened set, or a class-level collapse each fails it, so the memory's ungated-row and varargs traps do not apply to this handler. `denyEverything` accepts both varargs shapes (:224-235). |
| Coarse layer | `/v3/**` requires `WMS_USER_ROLE` (`SecurityConfiguration:178`). |
| No SDR / `/rest/**` exposure | `@RepositoryRestResource(... exported = false)` (`AdvicepositionRepository.java:26`). The projection is an interface and is not a repository. The diff adds no `controller.rest` handler. The only caller is `ViewDtoService:1045`. |
| SQL injection | Every input is a bound `:param` (`from`, `to`, `clientNumber`). The `~` and `regexp_replace` patterns are literals applied to stored columns, never to user input. The controller accepts no `sort` parameter: it passes `PageRequest.of(page, size)` (unsorted) and the `ORDER BY` is fixed in the query, so Spring cannot append a client `Sort`. |
| Page bounds | `checkPageBounds(page, size)` rejects `size<=0`, `page<0` and `size>api.paging.max-size=5000` (`AdminController:58-66`). A `null` page or size cannot occur because both are required `@RequestParam`. `from<to` is enforced. |
| Response fields | Advice, position, GR, item, UL and lane identifiers only. No user ids, operator ids, emails or names. |
| Multi-tenancy | The repository is in `net.aim_ai.wms.repo.jpa`, which is the tenant PU (`TenantDatabaseConfig:28`). The landlord PU is `landlord.jpa`. All joins stay inside one tenant DB. |
| Logging / secrets | One new log line, `LOG.info("RETURN advice fully received, marked FINISHED: adviceId={} adviceNumber={} positions={}"`, logs ids and counts only. The diff adds no credential, token or password literals. The diff does not touch `pom.xml`, so it introduces no new dependencies (I ran no dependency audit; nothing to audit). |

## Findings

### L1 (Low): the date range is unbounded, so each call re-scans `unitload_record`
- **Location:** `ReportController.returnsAudit` validates only `!from.isBefore(to)`. In `AdvicepositionRepository.findReturnsAudit`, the `ur` CTE is
  `FROM unitload_record r WHERE r.activitycode = 'RETURN' AND r.ordernumber IN (SELECT ap.number ...)`.
- **Evidence (WineCo PRD, 2026-10-15):** `unitload_record` has about 6.8M rows (`reltuples` 6,805,807). There is no index on `ordernumber` or `activitycode` (`pg_indexes`). The all-time `ur` derived table took about 0.5 s and returned 10,173 rows. The CTE runs again on **every** page, and the count query runs on every page as well.
- **Scenario:** a user holding `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` pages `from=2000-01-01&to=2100-01-01&size=5000`, or scripts it in a loop. Each request is a 0.5 s+ seq scan on a hot table. The caller must be authenticated and function-gated, and the cost per call is bounded, so this is not a realistic outage. It is a cheap amplification, though.
- **Fix:** cap the window in the controller, as below. Optionally add a lower `size` cap for this endpoint.
  ```java
  if (Duration.between(from, to).compareTo(Duration.ofDays(366)) > 0) {
      throw new ApiInvalidParameterException("date range may not exceed 366 days", "to");
  }
  ```

### L2 (Low, test gap): no allow-path control for `/returnsAudit`
- **Location:** `ReportReadGateUnitTest` adds `returnsAudit_shouldBeForbidden_*` (403 on both prefixes) and the exact-function pin, but adds **no** `isEqualTo(200)` row to the existing allow control `gatedEndpointsAreReachableWhenTheFunctionIsHeld`.
- **Why it matters:** an over-gate would not turn either test red. The same holds for a post-guard 500 on either prefix, for example a missing `@DateTimeFormat` making `OffsetDateTime` binding fail, or the dashboard twin not binding. The file's own comment calls the allow control "the ONLY over-gating detector".
- **Fix:** with `allowEverything` and the `ViewDtoService` mock stubbed, assert `get("/v3/report/returnsAudit" + RETURNS_AUDIT_QUERY)` and the `/v3/dashboard/...` twin both `isEqualTo(200)`. Mutation-check the assertion by removing `@DateTimeFormat` and confirming red.

### L3 (Low, latent): the merchant-order lookup is not client-scoped
- **Location:** the `co` CTE: `SELECT DISTINCT ON (o.externalnumber) ... FROM customerorder o WHERE o.externalnumber IN (SELECT adv.parcel_id FROM adv) ORDER BY o.externalnumber, o.id`, joined `LEFT JOIN co ON co.externalnumber = adv.parcel_id`. It has no `o.client_id = advice.client_id` predicate.
- **Mitigation, measured:** `customerorder.externalnumber` has a **UNIQUE** constraint (`V2.2.00__base_v2_schema.sql:3308`), so "lowest id wins" can never pick between rows and the `DISTINCT ON` is redundant. On WineCo PRD, 0 of 2,822 RETURN advices have a parcel_id that matches another client's order, and 0 have multiple matches.
- **Residual:** a caller filtering `clientNumber=X` could see client Y's `clientordernumber` only if a RETURN parcel id collided with another client's order `externalnumber`. These are OMS-global ids, so that is unlikely.
- **Fix (defence in depth, cheap):** carry `a.client_id` in `adv` and add the client predicate to the lookup, as below.
  ```sql
  LEFT JOIN co ON co.externalnumber = adv.parcel_id AND co.client_id = adv.client_id
  ```
  This needs `o.client_id` selected in `co`.

## Informational
- **I1: the client filter is optional and not bound to the caller's client.** An empty or absent `clientNumber` returns every client's returns in the warehouse tenant. This matches the sibling `exportReceiving` path (`ReportService:171`, where the filter comes straight from the request body), and no web report scopes by `ClientService.getUserClient()`; only mobile replenish/picking do. It is not a regression. If client-partitioned web users are ever introduced, every report needs this, not just this endpoint.
- **I2: function choice.** No dedicated returns-audit screen exists yet, so the endpoint takes the Receiving Report's existing `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` (the `exportReceiving` pair at tranche rows 202-203). That follows "gate on its screen's existing function" as closely as possible. If a UI screen ships under a different menu function, re-point the gate and both pin rows in the same change.
- **I3: `ApiInvalidParameterException` messages** echo only fixed strings (`"'from' must be before 'to'"`). No user input is reflected, so there is no XSS or log-injection surface.

## Security checklist
- [x] No hardcoded secrets in the diff
- [x] All inputs validated (date order, page bounds); date-range **span** is not bounded (L1)
- [x] Injection prevention verified (bound params, no client sort, literal regexes)
- [x] AuthN (`/v3/**` → `wms_user`) and AuthZ (method-level `@RequiresFunction`, both prefixes, real-guard 403 tests) verified; allow-path control missing (L2)
- [x] No SDR / `/rest/**` exposure
- [x] Tenant PU only
- [x] Dependencies unchanged (no `pom.xml` diff)
