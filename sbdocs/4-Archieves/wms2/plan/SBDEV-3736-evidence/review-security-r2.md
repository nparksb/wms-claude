---
ticket: SBDEV-3736
lane: security-review r2 (scoped to the review-fix commits)
head: a538785e24419d34204cb39f7437435f23896582
base: 666fe51a
scope: git diff 666fe51a..HEAD (e095df5c, 339da0fc, dab72eeb, 889da101, c9e05f29, a538785e)
date: 2026-10-15
db: wsl-wineco-prd (read-only: one SELECT, one EXPLAIN without ANALYZE)
verdict: PASS-WITH-LOWS
counts: {critical: 0, high: 0, medium: 0, low: 1, info: 4}
r1_status: {L1: PARTIAL, L2: RESOLVED, L3: RESOLVED}
---

# SBDEV-3736: security review, round 2

**Scope:** I reviewed the six fix commits in `git diff 666fe51a..HEAD`. The production files are:
- `ReportController.returnsAudit`
- `AdvicepositionRepository.findReturnsAudit` (both the content query and the count query)
- `ReturnsAuditView`
- `ViewDtoService.getReturnsAudit`
- `ReceivingService.finishReturnAdviceIfComplete`

I also read the test diffs to judge L2. I did not run Maven or modify the worktree.

**Risk level:** LOW.

## Round-1 findings

| # | Status | Basis |
|---|---|---|
| L1: unbounded window | **PARTIAL** | The cap works: it is correct, it cannot be bypassed, and it is tested at the boundary. It does **not** bound the dominant cost, though. The `unitload_record` seq scan runs on every page whatever the window. The residual is R2-L1 below. |
| L2: allow-path 200 on both prefixes | **RESOLVED** | See below. |
| L3: merchant-order join not client-scoped | **RESOLVED** | See below. |

### L1: the cap itself
- **Bypass via null `from`/`to`.** Both parameters are required `@RequestParam`s. A missing `to` returns 400 through the real `RestExceptionHandler` (`returnsAudit_shouldReject_whenToIsMissing`). An empty value (`from=`) converts to null, and Spring 6 raises `MissingServletRequestParameterException` for it, which is the same 400 path. The handler can never see null, so `Duration.between` cannot NPE.
- **Timezone tricks.** `Duration.between(OffsetDateTime, OffsetDateTime)` compares instants, so mixing `+14:00` and `-12:00` offsets cannot stretch the absolute span. DST does not apply to fixed offsets. The `%2B` binding test shows the instant reaching the service unchanged.
- **Order of the checks.** `!from.isBefore(to)` runs first, so the Duration is always positive. A negative span cannot slip under the cap.
- **Boundary.** The cap is inclusive at exactly 366 d. One second over returns 422 and the service is never called. Mutants K5 and K6 are reported KILLED.
- **Cap is per request only.** A caller can tile many 366-day windows. That is inherent to the design, and each request is still bounded and gated.
- **Gap the cap leaves.** See R2-L1.

### L2: the allow path really goes through the guard
- `gatedEndpointsAreReachableWhenTheFunctionIsHeld` calls `setupMockMvcWithGuard(reportController|dashboardController, guard)`.
- `guard` is a real `new FunctionGuardInterceptor(accessService, …)` (ReportReadGateUnitTest:183). It is registered via `.addInterceptors` (BaseControllerUnitTest:106), so `preHandle` runs on both requests.
- The assertions are `isEqualTo(200)`, not `isNotEqualTo(403)`, so a post-guard 500 or 400 also fails them.
- Mutants K7c (GET→POST, 405) and K7d (dashboard remapped) are KILLED. The prefix-specific failure messages show each leg is independently load-bearing.
- **What this control can and cannot catch.** The stub is `allowEverything`, so on its own it cannot catch a re-pointed function. That case is covered by the exact-function pin `assertFunction(ReportController.class, "/returnsAudit", F_RECEIVING)` and by tranche rows 207–208. The two together cover over-gating by both denial and wrong function.
- **Residual blind spot (pre-existing, not introduced).** Standalone MockMvc has no method-security proxy, so an added `@PreAuthorize` would not turn this red. Grepping the diff shows no such annotation was added.
- The fixer's report that removing `@DateTimeFormat` is an equivalent mutant (K7/K7b survive) is plausible: Spring converts String to `OffsetDateTime` via ISO parsing. It is not a security concern.

### L3: client-scoped merchant-order join
- The `adv` CTE now carries `a.client_id`, and the join is `LEFT JOIN co ON co.externalnumber = adv.parcel_id AND co.client_id = adv.client_id`. A collision with another client's order can no longer surface that client's `clientordernumber` or `parcelexternalnumber`.
- Dropping `DISTINCT ON` is safe for **confidentiality** whether or not the UNIQUE index exists: every row that survives is the advice's own client's.
- The UNIQUE `index_customerorder_externalnumber` matters only for **cardinality**. If the index were missing on some tenant, duplicate rows would inflate the content query against the count query (see I-2). That is a correctness question, not a data-exposure one.
- Covered by JDBC IT A15 and Spring IT RB01. Mutant S3 is KILLED.

## New surface added by the fixes

| Item | Verdict |
|---|---|
| `receivedBy = mywms_user.name` via `LEFT JOIN mywms_user ru ON ru.id = g.operator_id` | Acceptable; see I-1. The query selects only `name`. It does not select `password`, `client_id` or any role or credential column. |
| `carrierParcelId = customerorder.parcelexternalnumber` | Acceptable. This is a carrier tracking id, scoped to the same client by the L3 predicate. It is the same class of data as the r1 fields (parcel id, merchant order). It is not PII. |
| New bound parameters | None. The query still binds only `:from`, `:to` and `:clientNumber`. `a.client_id`, `ru`, `parcelexternalnumber` and `coalesce(received = notifiedamount, false)` are all static SQL. There is no concatenation of user input and no client `Sort` (`PageRequest.of(page, size)` is unsorted). |
| Count query | It gained only `a.client_id` in `adv`, with no new joins. The contract test pins that the `mywms_user` and `customerorder` lookups stay out of it (mutant S8 KILLED). |
| Logging | Grepping `+` lines for `LOG.`/`log.`/`LOGGER`/`System.out`/`password`/`secret`/`token` finds no new production logging. The only hit is a test fixture: `INSERT INTO mywms_user (…password…) VALUES (8736020, …, 'returns-clerk', 'x', …)`. That is a dummy value in a rolled-back IT, not a secret. |
| `ReceivingService` finisher changes | These are authorization-neutral. Requiring an exact match narrows when an advice auto-finishes, so it is fail-safe. The id-ordered saves and the FINISHED filter add no new data flow. |
| Gate | Unchanged. `@RequiresFunction(WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW)` at ReportController:438 is outside every diff hunk. The tranche pins at Sbdev3017TrancheGateContextTest:207–208 cover both `/v3/report/returnsAudit` and `/v3/dashboard/returnsAudit`. No other `src/main` reference to `returnsAudit` exists, so there is no new route or SDR exposure. |
| Dependencies | `pom.xml` and `src/main/resources` are untouched, so there was nothing to audit. |
| Error messages | The new 422 message is a fixed string plus a constant (`"the date range may not exceed 366 days"`). It reflects no user input. |

## Findings

### R2-L1 (Low; residual of r1 L1): the window cap does not bound the per-page `unitload_record` seq scan
- **Category:** A04 Insecure Design / resource consumption.
- **Location:** `AdvicepositionRepository.java`, the `ur` CTE:
  ```sql
  FROM unitload_record r WHERE r.activitycode = 'RETURN'
    AND r.ordernumber IN (SELECT ap.number FROM adviceposition ap INNER JOIN adv ON adv.id = ap.advice_id)
  ```
- **Evidence:** WineCo PRD, `EXPLAIN` of the `ur` CTE with a 366-day window:
  - `Seq Scan on unitload_record (Cost 0.00..183227.36) Filter: activitycode = 'RETURN'`
  - The plan is the same shape as the all-time window from r1.
  - The window shrinks only the 1,284-row advice-position side of the merge join. The 6.8M-row scan is fixed cost per request.
- **Exploitability:** remote, but only for an authenticated `wms_user` holding `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW`.
- **Blast radius:** about 0.5 s of DB CPU and I/O per page on the tenant DB. The window cap does not reduce that cost, but it does bound the number of pages per window. At `size=5000` a 366-day window is about 1 page; r1 measured 10,173 all-time rows. So a single sweep is cheap, and the remaining risk is a scripted loop. Rated Low.
- **Doc accuracy:** the new javadoc on `MAX_RETURNS_AUDIT_WINDOW` says the cap answers "every page re-runs a unitload_record scan". It caps the pages, not the scan. Reword it so a later reader does not assume the scan is bounded.
- **Fix (pick one):**
  - **(a) Accept**, and reword the javadoc. This is my recommendation for this ticket.
  - **(b) Follow-up (T3, because it needs a Flyway migration): add a partial index.** The `activitycode` predicate is a literal, so the "partial index unusable with a bind parameter" trap does not apply.
    ```sql
    -- V?.?.??__unitload_record_return_ordernumber_idx.sql
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_unitload_record_return_ordernumber
        ON unitload_record (ordernumber, label) WHERE activitycode = 'RETURN';
    ```
  - **Javadoc correction:**
    ```java
    // BAD:  "every page re-runs a unitload_record scan ... so an all-time window paged at the max size is a cheap amplification"
    // GOOD: "bounds the rows and pages per window; it does NOT bound the per-page unitload_record seq scan
    //        (no ordernumber index) — that cost is fixed per request and accepted (security r2 R2-L1)."
    ```

## Informational
- **I-1: `receivedBy` exposes a username, and there is precedent for it.**
  - On WineCo PRD, `mywms_user.name` is a login handle: 94 users, 0 containing `@`, 0 containing a space. It is not an email or a full name.
  - Existing gated siblings already return the same field:
    - `GoodsreceiptpositionRepository.getDetailViewByAdvicePositionId`: `usr.name as user`, joined on `grp.operator_id`. This is the same join and the same data, on the receiving detail view.
    - `ViewDtoService:525`: `"user"`.
    - `ViewDtoService:1158`: `"operator"`.
  - The exposure is consistent with the Receiving Report's function. If a tenant ever stores emails as usernames, this becomes PII; that would apply to every one of these reports, not only this endpoint.
- **I-2: the UNIQUE index premise was checked on 4 PRD tenant DBs, but the estate census is 6.** Dropping `DISTINCT ON` is confidentiality-safe either way (see L3). If a dev or UAT tenant lacks `index_customerorder_externalnumber`, the worst case is duplicated content rows and a mismatch between content and count. A one-line `pg_indexes` check on the remaining tenants would close this.
- **I-3: the client filter is still not bound to the caller (r1 I1).** This is unchanged and matches the sibling reports. It is not a regression.
- **I-4: `@PreAuthorize` over-gating is invisible to the standalone-MockMvc allow control.** This blind spot is pre-existing and repo-wide. The diff adds no `@PreAuthorize`.

## Security checklist
- [x] No hardcoded secrets (the test-fixture `'x'` password is a dummy in a rolled-back IT)
- [x] Inputs validated: required `from`/`to`, ordering, a 366-day span checked instant-wise, and page bounds
- [x] Injection prevention: no new bound params, no concatenated input, no client sort
- [x] AuthZ unchanged and enforced on both prefixes; allow and deny paths both go through the real `FunctionGuardInterceptor`; exact-function pin present
- [x] Cross-client exposure closed on the merchant-order join (L3)
- [x] New fields reviewed: `receivedBy` has precedent, `carrierParcelId` is client-scoped
- [x] No new sensitive logging
- [x] Dependencies unchanged
- [ ] Per-request scan cost: bounded by the gate only, not by the cap (R2-L1, accepted or follow-up)
