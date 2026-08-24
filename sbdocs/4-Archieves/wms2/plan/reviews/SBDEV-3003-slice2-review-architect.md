---
title: "SBDEV-3003 Slice 2 — architect review lane (filter scope, key policy, auth position)"
ticket: "SBDEV-3003"
type: review
lane: architect
version: v2
reviewed: "SBDEV-3003-slice2-transfer-stock-idempotency.md draft r1"
base: "origin/develop (wms2-api 60aef02, wms2-mobile-ui 7f83d55)"
created: 2026-08-20
updated: 2026-08-20
tags: [review, wms2, slice2]
---

# Architect lane — Slice 2 (`/v3/stockUnit/transferStock` idempotency)

> **Provenance.** Delivered as a message after the lane initially went idle without reporting; persisted
> here on receipt so it survives the session. **H1, H2 and H3 were independently re-verified by the
> orchestrator against the code before any of them was acted on** — all three confirmed; see the
> verification note under each. Findings below are the lane's, in its own structure.

**Read by the lane:** the whole 217-line plan; `IdempotencyFilter` (355), `RestIdempotencyService`
(208), `RestIdempotencyRepository`, `RestIdempotencyCleanupJob`, `SchedulingEnablementConfig` /
`SchedulingConfiguration`, `SecurityConfiguration`, `TenantFilter`, `TenantDynamicRoutingDataSource`,
`StockUnitController`, `StockunitService.transferStock`,
`StockunitBusinessService.transferStockToUnitLoad`, `application.properties`; both UIs'
`plugins/axios.js`, `store/moveStock.js`, `components/moveStock/scanDestination.vue`,
`store/handlingUnits/stockUnits.js`, `components/handlingUnits/popups/transferStock.vue`; the existing
`IdempotencyFilterUnitTest`. Read-only throughout.

## Bottom line

**The central design is correct.** §1 was attacked and held — confirmed via the payload builder and the
source-stockunit mutation. §2 and §3 are also correct as written.

**But not safe to implement as written.** It misses one defect that makes the fix actively harmful (H1),
builds its whole test strategy on a false premise contradicted by a test file already in the repo (H2),
and lists `require-auth=false` in the grounding table without noticing the filter sits *upstream of
authorization* (H3).

---

# HIGH

## H1 — `transferStock` returns **HTTP 200 with an `errors` body** on business failure. The filter persists every 2xx. A *failed* move is cached as a success and replayed for 7 days.

> **Verified by the orchestrator:** `StockUnitController:127-130` is
> `errorMap.put("errors", errors); return ResponseEntity.ok(errorMap);` — and
> `RestIdempotencyService:192` is `if (status < 200 || status >= 300)`, so only non-2xx is dropped.
> Confirmed.

Every `BusinessException` / `FacadeException` / `EntityNotFoundException` out of
`stockunitService.transferStock` lands as **200**, so the error body is persisted as the cached response.
Two operator-facing consequences, both worse than the phantom unit loads:

1. **Retry after the cause is fixed → permanently stuck.** Destination locked → `200 {"errors":[…]}`
   cached under nonce N1. The store only resets on success (`store/moveStock.js:196` `commit('initialize')`
   sits in the `else` branch), so N1 is still live. Supervisor unlocks the container, operator taps Submit
   again, same body → **REPLAYED** → cached failure returned → same toast, forever. The move can never
   complete under N1.
2. **Correct the input → 409.** A different destination means same nonce, different body → `CONFLICT` →
   per §3 the UI must **show** it. The operator sees `idempotency-key-conflict` and is stuck.

Independent corroboration that this 200-on-failure shape is load-bearing:
`wms2-web-ui/cypress/e2e/wms/transfer-offsite/transfer-offsite.cy.js:251` — *"silently fail transferStock
— the API returns 200 but doesn't move"*.

**Fix, both layers.** Client: re-mint or clear the nonce on the `results.errors` branch too
(`store/moveStock.js:193-195`). Server: the allow-listed path must not cache a 2xx whose body carries an
`errors` key — the honest fix, independent of any client getting the lifecycle right, and the same
"code guarantee, not a config/client claim" standard §2 already applies to bridge-mode. Verify row +
mutation check.

## H2 — §5's founding claim is false. A unit test *can* catch a filter-scope regression, and the repo already has 435 lines of exactly that test.

> **Verified by the orchestrator:** `src/test/java/net/aim_ai/wms/unit/landlord/IdempotencyFilterUnitTest.java`
> exists (22 KB) with **12** `filter.doFilter(...)` call sites. Confirmed — the plan's premise was false.

The plan claimed *"No unit test can catch a filter-scope regression — `standaloneSetup` MockMvc does not
build the filter chain"* and derived its whole test plan from it, including relocating a test to poke
`protected shouldNotFilter`. But the existing test already drives the filter through its **public** entry
point (`MockHttpServletRequest` + `filter.doFilter(req, resp, chain)` + `verify(chain, never())`), and
`OncePerRequestFilter.doFilter` consults `shouldNotFilter` before delegating — so nine existing tests
already exercise the scope gate end to end, with no Spring context.

Worse, the plan's proposal is **strictly weaker than what exists**: a test poking `shouldNotFilter` goes
green even if `doFilterInternal` ignored scope entirely — the vacuous-green failure mode already recorded
twice in this repo.

**Instead:** extend `IdempotencyFilterUnitTest` in place. Allow-listed path → `verifyNoInteractions(chain)`
+ claim attempted; a *different* `/v3` POST → `verify(chain, times(1))` **and**
`verifyNoInteractions(idempotencyService)` (that second half is what makes the allow-list-vs-prefix
assertion non-vacuous); GET on the allow-listed path → out; `/rest/**` unchanged; `enforce=false` → out.
Keep the DEV curl matrix — only it covers Spring Security ordering — but it is no longer the *only*
evidence, which changes the cost/benefit of the whole slice.

## H3 — The filter runs **before** `AuthorizationFilter`, and `require-auth=false`. Enrolling an authority-gated `/v3` path makes an unauthenticated POST do a DB write — and with no tenant header it writes to the **landlord** DB and 500s.

> **Verified by the orchestrator:** `SecurityConfiguration:151` gates `/v3/**` with
> `hasAnyAuthority("wms_user")`; `:160-162` adds the filter after `BearerTokenAuthenticationFilter`;
> `TenantDynamicRoutingDataSource:51-54` returns the default (landlord) datasource when
> `tenantProfile == null`. Confirmed. **Additional corroboration:** the wiring comment at
> `SecurityConfiguration:157-159` states the filter *"MUST run AFTER OAuth2 resource-server auth so
> unauthenticated callers cannot force tenant DB hits"* — precisely the invariant `require-auth=false`
> defeats. The code documents the rule it is currently breaking.

- In Spring Security 6 `AuthorizationFilter` is **last**, so the filter runs before the `wms_user` check.
  Authorization has not happened when `tryClaim` fires.
- With `requireAuth=false` the filter's own 401 gate (`IdempotencyFilter:120-128`) is skipped. A POST with
  **no `Authorization` header at all** passes `BearerTokenAuthenticationFilter` untouched and reaches
  `doFilterInternal`. (An *invalid* token 401s at the bearer filter and never gets here — it is
  specifically the no-header case.)
- `TenantFilter` is `@Order(HIGHEST_PRECEDENCE)` and sets tenant context to `null` when headers are absent.
- `rest_idempotency` does not exist in the landlord DB (tenant-PU entity), so `insertClaimIfAbsent` raises
  `42P01` out of the filter → **500**.

So enrolling the path converts "no auth / bad tenant header → clean 401/403" into "500 from a landlord-DB
write attempt", and with a well-formed tenant header into two pre-authorization tenant-DB roundtrips per
anonymous request. `/rest/**` is `permitAll`, which is why `require-auth=false` was benign there. `/v3/**`
is not.

**Instead:** for allow-listed `/v3` paths, require authentication **in code, regardless of
`app.idempotency.require-auth`** — the exact inverse of §2's bridge-mode requirement, on the argument the
plan already makes. It is free: the path already requires `wms_user`. Flipping `require-auth=true` later
does **not** break the enrolled path. And note this trips the plan's own §7 *"scope change reaches an
auth-adjacent path"* trigger.

---

# MEDIUM

**M1 — Slice 2 leaves the endpoint's other client undeduped, and the plan never mentions it exists.**
Two production callers: `wms2-mobile-ui/store/moveStock.js:187` (the plan's only subject) and
`wms2-web-ui/store/handlingUnits/stockUnits.js:159` via `popups/transferStock.vue:113`. Under fail-open
(i) the web UI sends no nonce → never deduped. *In fairness to (i):* the web popup sets `loading = true`
at `:97` before the `await` and its button is `:loading`-bound (`:48`), and Vuetify disables a loading
button — a de-facto re-entry guard, with a mouse click rather than a scanner CR as the trigger. **So (i)
is right and the lane endorses it over (ii)**: (ii) would hard-break the web UI *and* every older field
mobile build on deploy day. State the residual explicitly instead.

**M2 — "Axios retry must reuse it" targets a retry path that does not exist.**
`plugins/axios.js:35-39` (both UIs): `retryCondition` returns `false` unless the status is 401 or 403 —
and `!error.response`, exactly the transport-failure/timeout case, returns **false**. There is no
automatic retry of a timed-out `transferStock` anywhere. What actually matters is surviving an **operator
re-tap and a component re-mount**, and the plan has no test for that. *Silver linings:* 409 is not
retried (no storm), and `error.response.data.error` is readable (both 409 bodies set
`application/json` — `IdempotencyFilter:189-193`, `:218-222`), so **§3 is implementable as written**.
**Landmine the plan misses:** set the nonce per-request, **never** on `config.headers.common` —
`plugins/axios.js:126-155` puts `Authorization`/`X-Tenant-ID`/`facility_code` there, and a nonce on
shared defaults leaks into every later request so the *next* transferStock reuses a stale nonce →
REPLAYED or CONFLICT. Same bug class as SBDEV-2726, in the same file.

**M3 — `crypto.randomUUID()` is not unconditionally available.** Zero uses across both UIs (excluding
`node_modules`); no `uuid`/`nanoid` in either `package.json`. It requires a **secure context** — on a
handheld WebView over plain HTTP, or an older Android WebView, it is `undefined` → `TypeError` inside
`submit()` → **the move never fires at all**. jsdom may not expose it either. Specify a fallback
(`crypto.randomUUID?.() ?? hex from crypto.getRandomValues ?? …`) and cover the fallback branch in Jest.

**M4 — the new request header depends on an env-overridable CORS setting.**
`application.properties:99` is `rest.security.cors.allowed-headers=*` (fed to
`corsConfiguration.setAllowedHeaders`), so the `Idempotency-Key` preflight passes by default — but the
property is env-overridable, and SBDEV-2632 exists because an environment overrode the sibling
`exposed-headers`. If any env pins an explicit list, the preflight fails, the request never leaves the
browser, and Move Stock breaks **entirely**, surfacing as the generic "network or server issue" toast.
Add a per-environment pre-deploy check. Per this repo's record, neither curl nor the DevTools Network
panel reliably verifies CORS header handling.

---

# LOW

**L1 — the counter probably doesn't belong in the filter.** `IdempotencyFilter` is **not a Spring bean** —
it is `new`-ed in `SecurityConfiguration.filterChain:160-162`, so threading a `MeterRegistry` drags the
security config into a metrics change. `RestIdempotencyService` **is** a bean and sees every `ClaimResult`
at `tryClaim`'s returns: no `SecurityConfiguration` change, trivially registry-assertable in the existing
`RestIdempotencyServiceUnitTest`, and a `/rest/**` baseline for free.

**L2 — blast-radius numbers wrong in detail, direction confirmed.** See Q3 below.

**L3 — the 60 s stale-claim TTL is also a duplicate-execution window.** `RestIdempotencyService:117-129`
deletes and re-claims any `102` row older than 60 s. If the first `transferStock` legitimately runs >60 s
(the existing-container pallet branch does several writes plus `transferUnitLoadToCarrier`), a re-tap with
the same nonce **re-claims and executes a second move**. Same if `persistResponse` fails — it is caught and
merely warned (`IdempotencyFilter:247-249`), leaving the row at `102`. Low probability; one sentence so
nobody reads "nonce ⇒ exactly-once".

**L4 — citation drift.** §2 cites `:145-162`, the branch is **147-162**. §0's outcomes row cites `:185-224`
in a service-titled column; those are `IdempotencyFilter` lines (**188-224**). `RestIdempotencyCleanupJob:20,29`
are javadoc; the constant is `:30`, the cron `:48`.

---

# The five questions, answered

**Q1 — byte-identical across a deliberate repeat move? YES. §1 holds; auto-derive stays rejected.**
`scanDestination.vue:217-224` builds seven fields — `id`, `amountToTransfer`, `printLabel`, `locationName`,
`labelId`, `isTransferExistingContainer`, `comment` — with no timestamp, UUID, generated label id, or
sequence; `store/moveStock.js:188` posts it verbatim. A **partial** transfer decrements the source **in
place** under the same PK (`transferStockToUnitLoad:188`), so after moving 12 of 50 the source keeps its id
and holds 38, and "move 12 more, same destination, same comment" re-sends **identical bytes → identical
`SHA-256(method|path|body)`**. Both destination modes are stable (`existing` pins
`locationName='Clearing'` + scanned label, `:194-195`; `new` uses the typed location with `labelId` = the
*source* UL, `:201-202`). Bodies necessarily differ only for a **full** transfer (source deleted → the
repeat 404s rather than duplicating) or a different amount — neither rescues auto-derive. **The design
does not get simpler.** Two points to add: the replay is worse than "silent" — the store's success branch
fires on the cached `true`, so the operator gets a green **"Stock moved"** for a move that did not happen;
and `wms2-web-ui` uses a **different key order** for the same intent
(`popups/transferStock.vue:100-107`), making the body hash client-serialization-dependent.

**Q2 — all ~10 grounding claims held.** None wrong; two incomplete (H3, and the retention trap). Notable:
the **7-day retention survives a non-obvious trap** — `app.cron=false` is the default and
`SchedulingConfiguration` is `@ConditionalOnProperty(app.cron=true)`, but `@EnableScheduling` is
unconditional in `SchedulingEnablementConfig` and `RestIdempotencyCleanupJob` is a plain `@Service` with
`@Scheduled` (`:26,:48`), **not** registered through the gated config — so it runs on every replica
regardless, advisory-locked. 7 days is real. (Minor: `deleteOlderThan(Instant)` converts via
`ZoneId.systemDefault()` against a UTC-stored `created_at`, skewing the cutoff by the JVM offset.
Immaterial.) **§2 bridge-mode confirmed:** `findByRequestHashAndMethodAndPath` keys on
`(requestHash, method, path)`, **ignores the key**, filters `responseStatus BETWEEN 200 AND 299`, and the
just-inserted claim is `102` so it cannot self-match — a fresh nonce is fully defeated. No simpler correct
answer exists than skipping the branch for allow-listed paths.

**Q3 — real blast-radius numbers; claim confirmed and understated.** **62** `@RestController` classes
(not 61), all with class-level `@RequestMapping`; **52** mapped under `/v3` (8 × `/rest/*`, 2 ×
`/api/public`). `AdminController:29` is `@RequestMapping("/v3")` with **43** subclasses and **5 non-GET**
methods (`/user/deleteUserByUsername`, `/user/createUser`, `/user/updateUser`, `/user/resetPassword`,
`/groups/findGroup`, at `:121,143,155,176,225`), each re-registered under every subclass prefix — so
`/v3/stockUnit/user/createUser` is a live POST. ⇒ **~215 non-GET endpoints invisible to a mapping grep**,
plus every business write across the 52 controllers.

**Q4 — `require-auth=false`: a real interaction, both directions.** See H3. Flipping it to `true` later
does not break the enrolled path (only the `permitAll` `/rest/**` OMS callers, pre-existing).

**Q5 — what the plan missed.** `printLabel` on replay: real but currently harmless — `StockunitService:296-297`
gates on the flag and mobile hard-codes `printLabel: false` (`scanDestination.vue:219`); the **web UI**
exposes it as a switch (`popups/transferStock.vue:43,104`), so extending the nonce there would let a replay
silently skip a label. `cacheEvictOnReplay` analogue **not needed — verified**: zero `@Cacheable`/`@CacheEvict`/
`@Caching` in `StockunitService`, `StockunitBusinessService`, `UnitloadService`. Tenant scoping **correct and
automatic**. Multi-replica **correct by construction**. Axios **would not** retry a 409. Plus H1, H2, H3, M1–M4.

---

# Verdict

**Central design sound** — nonce-required, auto-derive off, one-path allow-list, bridge-mode immunity, all
four confirmed against code, and §1 survived a direct attack on its weakest premise.

**Not safe to implement as written.** Required revisions, in order:

1. **H1** — handle 200-with-`errors`: don't cache such a 2xx on the allow-listed path; re-mint the nonce on
   the client's `errors` branch. Without this the fix makes a failed move unrecoverable and a corrected move
   a 409. Verify row + mutation check.
2. **H3** — require authentication for allow-listed `/v3` paths **in code**, independent of the property.
3. **H2** — rewrite §5: extend `IdempotencyFilterUnitTest` via `filter.doFilter(...)`; drop the false premise
   and the package relocation. Keep the curl matrix, add row 8: *no `Authorization` header on the allow-listed
   path*.
4. **M2 + M3** — restate the client requirement as "one nonce per operator intent, surviving a re-tap and a
   re-mount" (there is no transport retry); forbid `headers.common`; specify a `randomUUID` fallback.
5. **M1 + M4** — name `wms2-web-ui` as the second, uncovered caller and state fail-open (i)'s residual; add a
   per-environment CORS `allowed-headers` pre-deploy check.

**Tier:** T2 still fits — no table, no migration. H3 does trip the plan's own auth-adjacent trigger; the
lane's read is that it is answerable inside T2 via the code-level auth requirement rather than by
escalating. **That call is Nam's**, and the plan should record it either way.

<!-- LANE COMPLETE: findings=11 high=3 medium=4 low=4 -->
