---
title: "SBDEV-3003 Slice 2 — independent review of the wms2-api implementation (a8e2997)"
ticket: "SBDEV-3003"
type: "review"
lane: "api implementation review (independent)"
reviewed: "a8e2997 (fix) + 45bcf33 (TDD gate), net effect vs origin/develop 60aef02"
worktree: "/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3003-slice2"
project: [wms2]
version: v2
created: 2026-08-21
tags: [review, plan]
---

# Verdict

**Approve with changes.** The six sub-fixes are all present and behaviourally correct for the
happy path, and I could not break G-a/G-b/G-c/G-e's *runtime* behaviour — two probes I wrote
confirm the two properties the commit message asserts but does not test (the fail-open request
stays replayable, and the client still receives the real 200 + errors body). `shouldNotFilter`'s
reorder is exactly behaviour-preserving for `/rest/**` and non-`/rest` paths. Full suite
re-measured independently: **5236 run, 2 failures**, and both are the two known pre-existing
develop failures (`OptionalSafetyArchTest#noNewOptionalGetCallsInServiceClasses`,
`MobilePalletizingServiceTest#testScanParcelBulkPalletAlreadyAssignedToGate`).

Two things should change before the PR:

1. **G-f is an *authentication* gate where the threat model needs an *authorization* gate.** The
   42P01 → 500 that plan §1b says the fix eliminates is still reachable — by any principal holding
   a valid default-issuer JWT, including one with zero WMS authorities. That caller got a clean
   403 before this commit.
2. **The new counter's `path` tag is client-controlled on the `/rest/**` baseline.** Measured: 500
   distinct meters from 500 client-chosen paths. The javadoc's "bounded set of enrolled endpoints"
   is not true for the un-allow-listed half of the counter's reach.

Plus two **measured** test gaps: the single most consequential branch in the change (G-b's
fail-open) has a live 22/22-green mutant that would 500 every legacy handheld.

I found **no** authz bypass, no data-integrity defect, and no way to make a failed move cache as a
success.

---

# Findings

| # | Sev | Site | What breaks | Suggested fix |
|---|---|---|---|---|
| F1 | **Medium** | `RestIdempotencyService.java:221-222` (`countDuplicate`), reached from `:144,168,173,183,205` | The `path` tag is `request.getRequestURI()` — a **client-chosen string** — for every non-GET `/rest/**` request, not just the allow-listed one. `IdempotencyFilter.shouldNotFilter:142-147` admits *any* `/rest/**` URI whether or not a handler maps it, and `/rest/**` is `permitAll` (`SecurityConfiguration:124`) with `app.idempotency.require-auth=false` (`application.properties:167`). Two concurrent identical POSTs to `/rest/<junk-N>/x` yield `IN_FLIGHT` → one new meter per junk path, retained for the process lifetime and scraped by Prometheus. **Measured** (probe, `SimpleMeterRegistry`): 500 paths → **500 distinct meters**. The javadoc at `:216-219` asserts the opposite ("`path` is a bounded set of enrolled endpoints, so it is safe as a tag") — that claim is false for the `/rest/**` baseline the commit added "for free". | Bound the tag rather than the reach: keep a `Set<String>` of the paths the dedup layer actually enrols and emit `KNOWN.contains(path) ? path : "other"`. (Do not solve it by threading the allow-list into the service — that is the duplication G-a deliberately avoided.) |
| F2 | **Medium** | `IdempotencyFilter.java:180-188` | G-f gates on `auth == null \|\| AnonymousAuthenticationToken \|\| !isAuthenticated()` — i.e. **authentication only**. But `/v3/**` is `hasAnyAuthority("wms_user")` (`SecurityConfiguration:151`) and `AuthorizationFilter` runs last, so: (a) a principal with **zero** WMS authorities now performs a tenant-DB claim INSERT *before* the authority check (row is deleted afterwards by `persistResponse(403)`, so no lasting state — but it is a pre-authz write); and (b) with no `X-Tenant-ID`/`facility_code`, `MultiTenantJwtDecoder:48-57` falls back to the default `rest.security.issuer-uri` decoder (`:89-94`), `TenantContext` is null, `TenantDynamicRoutingDataSource.determineTargetDataSource:51-54` routes to **landlord**, and `rest_idempotency` ships only in `src/main/resources/db/migration` (tenant) — never in `db/landlord`. So **the exact 42P01 → 500 that §1b says G-f closes is still reachable**, one rung up the ladder, and that caller previously got a clean 403. | On an allow-listed path also require the authority the route requires: `auth.getAuthorities()` must contain `wms_user`, refuse `403` otherwise. That is a strict superset of the current gate and costs nothing. (Do *not* "fix" it by swallowing the `DataAccessException` around `tryClaim` — that would silently disable dedup whenever the tenant DB hiccups.) |
| F3 | **Medium** (test adequacy) | `IdempotencyFilter.java:244`; test `IdempotencyFilterUnitTest#doFilterInternal_should_failOpen_when_noHeaderOnAllowListedPath` | **Measured mutant, 22/22 GREEN.** Replacing `chain.doFilter(replayableRequest(request, bodyBytes), response)` with `chain.doFilter(request, response)` on the fail-open branch passes both gate suites unchanged. That mutant means every nonce-less transfer — the *legacy-handheld* case G-b exists to preserve — hands the handler an already-drained `ServletInputStream`, so `@RequestBody Map` deserialization fails and **every move from an un-upgraded handheld 500s**. The test asserts only `verify(chain).doFilter(any(), any())` against a `mock(FilterChain.class)`, which never reads the body. | Replace the mock chain with a lambda that reads the body: `FilterChain chain = (rq, rs) -> seen.set(new String(rq.getInputStream().readAllBytes(), UTF_8));` then assert `seen` equals the posted JSON. I verified this assertion reds on the mutant and greens on `a8e2997`. |
| F4 | **Low** (test adequacy) | `IdempotencyFilter.java:333-339`; test `…#doFilterInternal_should_notCache_when_2xxCarriesErrorsBody` | **Measured mutant, 22/22 GREEN.** Adding `cachedResp.setStatus(500)` next to `effectiveStatus = 500` passes both suites. That is precisely the commit message's headline safety claim ("the client still receives the handler's own 200 body via `copyBodyToResponse`") going unpinned — and if it ever broke, every business-failure move would surface as a 500 that `store/moveStock.js`'s catch renders as a generic network toast, hiding the real reason the move failed. The test captures only the `persistResponse` status; it discards the `MockHttpServletResponse`. | Keep the response object and add `assertThat(resp.getStatus()).isEqualTo(200)` + `assertThat(resp.getContentAsString()).contains("locked")`. Verified: reds on the mutant, greens on `a8e2997`. |
| F5 | **Low** | `IdempotencyFilter.java:100`, `:357-362` | `carriesErrors` is a raw, case-sensitive, quote-exact substring test. It is **correct for today's handler** — `StockUnitController:127-133` returns literally `true` on success and `{"errors":[…]}` on failure, so there is no false positive and no false negative right now (verified by reading the only 2xx-producing code on that route; every `@ExceptionHandler` in `RestExceptionHandler`/`RestEndpointExceptionHandler` returns non-2xx, so nothing else can produce a 2xx there). But it will fire on any future 2xx body that merely *mentions* `"errors"` anywhere, including inside a value, and will miss `"Errors"` or a unicode-escaped key. | Leave as-is for this slice, but a one-line comment saying the check is coupled to "success is the literal `true`" would stop the next person from widening it. If the response DTO is ever changed, switch to `objectMapper.readTree(body).has("errors")`. |
| F6 | **Low** | `IdempotencyFilter.java:155-156`, `:166` | Dedup bypass via a percent-encoded path. `getRequestURI()` is **undecoded**; Boot 3's `PathPatternParser` matches on the decoded path, so `POST /v3/stockUnit/transfer%53tock` reaches the handler while `isAllowListedV3` misses and the filter is skipped entirely. Trailing slash and matrix params are already rejected upstream (Boot 3 trailing-slash match is off; `StrictHttpFirewall` rejects `;` and `//`), and `%53`-style encoding is *not* firewall-blocked, so this is the one live variant. Harmless today because G-b already fails open with no nonce, so a bypass gains an attacker nothing — but it becomes load-bearing the moment G-b is tightened to option (ii) reject-400. | Compare against the parsed request path (`ServletRequestPathUtils.getCachedPathValue` / `getServletPath()`) instead of `getRequestURI()`, or note the dependency in the allow-list javadoc. |
| F7 | **Low** (observation, scope) | `StockUnitController.java:135` `@PostMapping("/bulkTransferStock")` | The web UI's bulk path performs the same `stockunitService.transferStock(...)` in a loop (`:173`) and is **not** enrolled. Per plan §4 this slice is mobile-only, so this is scope-as-designed — but combined with plan §1's note that `wms2-web-ui/popups/transferStock.vue:100-107` serialises the same intent in a **different key order**, the web double-submit stays entirely unprotected and cannot be fixed by auto-derive later either. | Record on the ticket; do not widen this PR. |
| F8 | **Nit** | `IdempotencyFilterUnitTest` `SIBLING` constant + comment ("A REAL sibling symbol") | `transferStockToUnitLoad` is a `StockunitBusinessService` method (`:179`), **not a mapped endpoint** — no `@*Mapping` produces `/v3/stockUnit/transferStockToUnitLoad` anywhere in `src/main`. The test is still valid as a substring-superset probe (which is its actual job), but the comment overstates it and a later reader may go looking for a route that does not exist. | Reword to "a real sibling *service* symbol, and a substring-superset of the enrolled path". |

---

# Checked and RULED OUT

Everything below I actively looked at and found **not** to be a problem. Silence elsewhere means I
did not reach it.

### Filter ordering and authz (brief item 1)
- **Anonymous caller reaching a tenant DB write on the enrolled path** — closed. `:180` `(requireAuth || v3AllowListed)` fires before `getContentLength()`/`drainToBytes`/`tryClaim`, and `refuseAnon_onAllowListedPath_whenRequireAuthFalse` pins it (401, `verifyNoInteractions(service)`, chain never invoked). Confirmed red at the gate (`45bcf33`: "expected 401 but was 200").
- **401 information leak** — none. Body is empty, no headers written; the only disclosure is a server-side `LOG.warn` of the URI. (Nit not worth a row: no `WWW-Authenticate` header, so the 401 does not match the resource server's own 401 shape.)
- **`/rest/**` anonymous regression** — none. `stillAllowAnonOnRest_whenRequireAuthFalse` passes genuinely (200, 4-arg `tryClaim` still called).
- **`AuthorizationDeniedException` escaping through the filter and being cached as a 200** — ruled out. `IdempotencyFilter` is inserted after `BearerTokenAuthenticationFilter`, i.e. **upstream** of `ExceptionTranslationFilter`, so an authorization denial is converted to a 403 response downstream and `cachedResp.getStatus()` is 403 → `persistResponse` deletes the row. (I checked this specifically because `catch (ServletException | IOException)` at `:314` does **not** catch `RuntimeException`, so an escaping runtime exception *would* be persisted as a 200-with-empty-body. No such path exists here: every `@ExceptionHandler` reachable from this route returns non-2xx, and `DispatcherServlet` resolves before the filter sees anything.)
- **CORS preflight** — no change. `OPTIONS` is non-GET and therefore in scope on the enrolled path, but `CorsFilter` sits earlier in the chain and short-circuits preflights when a config is registered; where no CORS config is registered the preflight would previously have been 401/403'd by `AuthorizationFilter` anyway, so the outcome is unchanged either way.
- **Tenant context availability at filter time** — fine. `TenantFilter` is `@Order(HIGHEST_PRECEDENCE)` (`TenantFilter:18-19`), so it runs before `FilterChainProxy` and `TenantContext` is populated for the routing datasource. (The *null*-context case is F2.)

### Fail-open key policy (brief item 2)
- **Request replayability** — correct, and I proved it: probe reading `rq.getInputStream()` inside a real chain lambda gets back the exact posted body on `a8e2997`. (The *test* for it is missing → F3.)
- **Nothing leaked or skipped versus the other exit paths** — correct. The fail-open branch returns before `MDC.put("idempotencyKey", …)` (nothing to correlate — there is no key), before `ContentCachingResponseWrapper` (nothing to cache), and before `persistResponse`. That is the right set. The other early exits (`:197` Content-Length cap, `:213` buffered-size cap) use the same shape, so this is consistent with the pre-existing pattern.
- **Blank header falls through to fail-open** — yes: `rawHeader.isBlank()` at `:222` routes a present-but-empty header into `:234`, which is the specified behaviour ("missing **or blank**").

### `tryClaim` overload restructuring (brief item 3)
- **Transaction actually applied on every entry path** — yes. The filter calls both overloads through the Spring proxy, so each entry gets its own `@Transactional`. The 4-arg → 5-arg call at `:114` is self-invocation, so the inner annotation is bypassed — but the *outer* 4-arg transaction is already active and both annotations are byte-identical (`tenantTransactionManager`, default `REQUIRED`, default `readOnly=false`, `rollbackFor={BusinessException, FacadeException}`), so there is no propagation or `readOnly` divergence to exploit. I checked this deliberately against the repo's documented "transactional tests are blind to propagation and readOnly" landmine; there is nothing here for a mutant to hide in, because the two annotations are the same annotation.
- **Stale-claim recovery** — unchanged. `deleteByIdempotencyKeyIfExists` + `insertClaimIfAbsent` at `:163-171` keeps its original control flow; the only edit is a `countDuplicate` call in the lost-race branch (`:168`) and in the non-stale branch (`:173`). Both are counting outcomes that *are* suppressed duplicates. The successful reclaim returns `CLAIMED` and is correctly **not** counted.
- **Bridge suppression is `&&`, not a replacement** — `:192` `if (bridgeMode && allowBridgeMode)`, so the `/rest/**` 4-arg contract (`allowBridgeMode=true`) is bit-for-bit unchanged, and `tryClaim_should_stillBridge_when_notSuppressed` pins it.

### G-e's mechanism (brief item 4)
- **Safe to report a 200 as a 500 to `persistResponse`** — yes. `persistResponse` (`:246-262`) treats non-2xx purely as "delete the claim row"; it never writes the status anywhere the client sees.
- **Client still receives the real 200 body** — **verified by probe** (status 200, body intact). `effectiveStatus` is a local; the wrapper's own status is untouched; `copyBodyToResponse()` at `:345` still runs. (The *test* for it is missing → F4.)
- **`ContentCachingResponseWrapper` interaction** — none. `getStatus()`/`getContentAsByteArray()` are read once in the `finally`, before `copyBodyToResponse()`, which is the documented order.
- **"errors ⇒ nothing happened" premise** — holds. `StockunitService.transferStock:155-156` is `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` and there is **no** `REQUIRES_NEW` anywhere in `StockunitService` or `StockunitBusinessService`, so a caught `BusinessException`/`FacadeException`/`EntityNotFoundException` has rolled the whole move back. Dropping the claim row therefore cannot enable a double-apply of partial work. I checked this because it is the one way G-e could have been actively unsafe.
- **False positives / negatives on today's route** — none; see F5 for the latent version.

### The counter (brief item 5)
- **`MeterRegistry` bean present in every profile / context startup** — verified, not argued. `spring-boot-starter-actuator` is **compile** scope (`pom.xml:52-55`) so `micrometer-core` and the `SimpleMeterRegistry`/`CompositeMeterRegistry` auto-configuration are always on the classpath (`micrometer-registry-prometheus` is `runtime`, `pom.xml:122-126`, and is not load-bearing for the bean). More importantly, `mvn test` *does* boot a real `@SpringBootTest(classes = StartApplication.class)` context on the H2 `integration` profile (`BaseIntegrationTest:22-26`), and `OmsNotificationConfigContextLoadTest` passes in my full-suite run — so the new required constructor argument on `RestIdempotencyService` is DI-verified, not just compile-verified. (This is the repo's "verify Spring bean changes with a context load, not just `clean compile`" landmine, and it happens to be covered here.)
- **Metric semantics** — correct. Never counted on `CLAIMED`; `CONFLICT` is also uncounted, which matches plan §4 G-d as written ("`REPLAYED`/`IN_FLIGHT`"). Cardinality is the problem, not the outcomes → F1.
- **Counter test rigour** — `countDuplicate_when_replayed_butNotWhenClaimed` asserts a real registry (per plan §5 item 6) and correctly asserts the count does **not** advance on `CLAIMED`. It does not assert the *tags*, so a tag-only regression would pass; given F1 that is worth one extra assertion but is not itself a defect.

### Scope correctness (brief item 6)
- **`shouldNotFilter` reorder is behaviour-preserving** — verified against the pre-image (`git show 60aef02:…`). Original order was `enforce → (null || !startsWith("/rest/")) → GET → stockcount/transactionreport`; new order is `enforce → null → GET → allow-list → !startsWith("/rest/") → stockcount/transactionreport`. For any `/rest/**` path the GET test simply moved earlier with the same verdict; for any non-`/rest` non-allow-listed path both versions return `true`. No `/rest/**` or non-`/rest` behaviour changes.
- **`server.servlet.context-path`** — **not set** anywhere in `src/main/resources/application.properties` (only `server.port=8088` / `management.server.port=8088`), and no `spring.data.rest.base-path` either. So `getRequestURI()` is the bare `/v3/stockUnit/transferStock` and the exact match hits. This was the highest-value single check in the brief: a context path would have made the whole fix a silent no-op *and* would have silently broken the pre-existing `/rest/` prefix test too.
- **The path the client actually sends** — `wms2-mobile-ui/nuxt.config.js:123` `baseURL = API_BASE_URL || 'http://localhost:8088/v3'` plus `$post('/stockUnit/transferStock', …)` ⇒ `/v3/stockUnit/transferStock`. An ingress that *adds* a prefix visible to the app would break the match, but `/api/**` is separately `permitAll` and no such rewrite exists in-repo.
- **Case and trailing slash** — `Set.contains` is case-sensitive and Spring's own matching is too, so `/V3/…` 404s rather than bypassing; Boot 3 trailing-slash matching is off by default so `/v3/stockUnit/transferStock/` 404s. Percent-encoding is the only live variant → F6.
- **Prefix-vs-exact reasoning** — independently confirmed the premise: `AdminController` is a base class for 43 controllers whose endpoints re-register under every subclass prefix, so a `startsWith("/v3/")` test really would have enrolled endpoints invisible to a mapping grep. Exact match is right.

### Test adequacy (brief item 7)
- **The two gate tests the fix commit EDITED** — both edits **strengthen** them, not weaken them:
  - `dedupe_when_pathIsAllowListed`: moved from stubbing/verifying the 4-arg to the 5-arg **and added `verify(service, never()).tryClaim(any(), any(), any(), any())`**. Mockito resolves the two overloads by arity, so this now pins both the scope *and* the suppression flag at the call site. Strictly stronger than the drafted version.
  - `notDedupe_when_getOnAllowListedPath`: adding `Idempotency-Key: NONCE-GET` is what makes the row discriminating at all — without it the mutant that deletes the GET gate lands on the fail-open branch and `verifyNoInteractions(service)` stays trivially true. I confirmed the reasoning by inspection: with the GET gate removed and no header, control reaches `:234` and returns before touching the service.
- **Uncovered branches I checked and judged acceptable** — `CONFLICT`/`IN_FLIGHT`/`REPLAYED` response shapes on the enrolled path (covered by the pre-existing `/rest/**` tests over the same code), the `maxBodyBytes` early exits (unchanged), `cacheEvictOnReplay` (unchanged, `/rest/sku/` only).
- **Gate/fix suites re-run independently**: `IdempotencyFilterUnitTest` 22/0, `RestIdempotencyServiceUnitTest` 9/0.
- **Not covered by anything, as the commit itself states**: nothing in this change boots a filter chain, reads a live registry, or touches a database. Plan §5's 9-row DEV curl matrix (rows 4, 6, 7, 8, 9 in particular) remains the only cover for Spring Security ordering, and **F2 is exactly the finding row 8 would have surfaced** if it had been run with a token that lacks `wms_user`.

### Hygiene
- No source edit left behind: probe file deleted, `IdempotencyFilter.java` restored from a pre-mutation copy, `src/test/resources/archunit_store` reverted after the full suite mutated it. `git status --porcelain` is clean in the worktree. Nothing committed or amended.
