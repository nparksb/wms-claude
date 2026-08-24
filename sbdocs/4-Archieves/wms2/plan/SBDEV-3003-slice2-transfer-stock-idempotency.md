---
title: "WMSv2 SBDEV-3003 Slice 2: server-side dedupe for /v3/stockUnit/transferStock — enroll the existing IdempotencyFilter under an explicit client nonce"
ticket: "SBDEV-3003"
ticket_url: "https://app.clickup.com/t/868ku68tw"
type: "bugfix"
priority: "medium"
status: "COMPLETE 2026-08-21 — merged, deployed to DEV, and the §5 curl matrix RUN IN FULL (§6e). wms2-api PR #176 (cdd85d9) + wms2-mobile-ui PR #40 (55435bf); Slice 1 merged alongside (#175, #39). ALL matrix rows PASS on live DEV including row 4 (a deliberate repeat under a fresh nonce DID execute) and row 9 (a failing 200-with-errors was NOT cached). Ledger reconciles exactly: source -4, destination +4, 3 claim rows, N4 absent. G-d counter confirmed in production with the bounded path tag from review F1. Two review lanes complete (§6c): 1 High + 7 Medium + 8 Low, all addressed. api suite 5238/2 known failures; mobile 176/176; 29 mutants all killed. CORRECTION recorded in §6e: the 'missing tenant headers -> landlord 500' residual actually returns 401 at JWT decode. STILL OWED: per-environment CORS preflight check and handheld QA only — both need a browser/device, not curl."
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-20
updated: 2026-08-21
archived: 2026-08-21
db_verified: true
related:
  - ./SBDEV-3003-move-stock-lost-update-inventory-inflation.md
  - ./reviews/SBDEV-3003-review-mobile.md
  - ./reviews/SBDEV-3003-review-api-verify.md
  - ./reviews/SBDEV-3003-slice2-review-architect.md
  - ./reviews/SBDEV-3003-slice2-row-discrimination.md
  - ./reviews/SBDEV-3003-slice2-review-api-impl.md
  - ./reviews/SBDEV-3003-slice2-review-client-impl.md
tags:
  - plan
---

> **ARCHIVED 2026-08-21 — merged and deployed to DEV, with verification still owed.**
>
> `wms2-api` PR #176 (merge `cdd85d9`) · `wms2-mobile-ui` PR #40 (merge `55435bf`). Slice 1 merged
> alongside (api #175 → `7c23646`, mobile-ui #39 → `682c015`). Combined Slice1+Slice2 state was
> trial-merged and tested before merging: api 5238 run / 2 failures (the two known pre-existing
> develop failures), mobile 188/188.
>
> **Acceptance script RETIRED 2026-08-21** to
> `sbdocs/4-Archieves/scripts/verify-SBDEV-3003-move-stock-lost-update-inventory-inflation.sh`.
> (Superseding the note written at this plan's own archival, which correctly said RETAINED at the
> time: the script's plan-id belongs to the two *parent* SBDEV-3003 plans, and those were still active
> then. Both were archived later the same day, so nothing active references it now. Final grading
> against `origin/develop`: **49 pass, 0 fail, 3 skip**.)
>
> **Matrix runner RETAINED at `sbdocs/9-System/scripts/curl-matrix-SBDEV-3003-slice2.sh`** — the §5
> matrix is not finished (see §6d), so this stays live rather than being archived with the plan.
>
> **Implementation worktrees removed 2026-08-21:** `wms2-api/SBDEV-3003-slice2`,
> `wms2-mobile-ui/SBDEV-3003-slice2`. Their absence is intentional, not a lost checkout — both HEADs
> were verified as ancestors of `origin/develop` first. The `wms2-api/SBDEV-3003` and
> `wms2-mobile-ui/SBDEV-3003` worktrees are **deliberately left in place**: they belong to the parent
> plans, which are still active.
>
> **⚠ STILL OWED, tracked on the ticket** (ClickUp comment `90110262948764`, because a reader of an
> archived plan should not have to infer this): §5 curl-matrix rows 1–6 and 9 plus the counter check —
> **including row 4, the row that proves a deliberate repeat move still goes through**, whose failure
> mode is the fix silently dropping real moves; the per-environment CORS check for the
> `Idempotency-Key` preflight; and handheld QA including the `randomUUID`-absent path. Rows 0, 7-scope,
> 8 and the GET gate DID pass on live DEV — see §6d.

# Slice 2 — dedupe the Move Stock transfer server-side

**Parent plan:** [[SBDEV-3003-move-stock-lost-update-inventory-inflation]] (§3 Fix E/G, §3.0 sequencing).
This doc is separate because Slice 1 is shipping now and mixing a shipped slice with an unstarted one
in one 613-line file is what produced the status drift cleaned up on 2026-08-20.

**Tier: T2** — 2 review lanes, ~½ day. **Not urgent:** the parent plan's DB verification reconciles
PNCC24 three ways (3,828 received = ledger = on hand), so Slice 2 buys container hygiene, not
inventory correctness. Slice 1 already removed the operator-visible trigger.

> **§7's *"the scope change reaches an auth-adjacent path"* escalation trigger fired** (see §1b) and
> **Nam ruled 2026-08-20: STAYS T2**, answered by the code-level auth requirement in G-f rather than by
> escalating. Recorded as a decision, not an assumption. The doc's length is over the T2 cap and stays
> that way deliberately — the review findings are the reason, and trimming substance to fit the tier
> would invert the point of the tier.

---

## 0. Grounding — what already exists (read before designing)

`IdempotencyFilter` (`landlord/config/`, 355 lines) + `RestIdempotencyService` (208 lines) are a
**complete production dedupe subsystem** from SBDEV-2222 / plan 260520. Slice 2 builds **no storage**:

| Fact | Site | Consequence for this slice |
|---|---|---|
| Scope is `uri.startsWith("/rest/")`, non-GET, minus `stockcount`/`transactionreport` | `IdempotencyFilter:99-109` | `/v3/**` is entirely unfiltered today — this is the whole gap |
| **No header → key is auto-derived as `SHA-256(method \| path \| body)`** | `:174-176`, `:326-340` | **The decisive finding — see §1** |
| Explicit `Idempotency-Key` header overrides, validated `[A-Za-z0-9_\-]{1,64}` | `:160-173` | The nonce channel already exists; no new header contract |
| Claim is an atomic `INSERT … ON CONFLICT DO NOTHING` | `RestIdempotencyService:136` | **Concurrency is already correct.** No unique-index work, no check-then-act gap — a concern raised pre-grounding and now retired |
| Outcomes: `CLAIMED` → handler · `REPLAYED` → cached 2xx replayed · `IN_FLIGHT` → **409** `idempotency-in-flight` · `CONFLICT` → **409** `idempotency-key-conflict` | `IdempotencyFilter:188-224` | Two *different* 409s with different meanings — see §3 |
| Stale `IN_FLIGHT` rows recovered after 60 s | `RestIdempotencyService:61` | A crashed replica cannot wedge a key |
| Rows retained **7 days**, purged by `RestIdempotencyCleanupJob` (02:00 daily, advisory-locked) | `RestIdempotencyCleanupJob:30,48` | A key is "remembered" for 7 days — the window in which a repeated key is a replay |
| `app.idempotency.enforce=true`, `bridge-mode=false`, `require-auth=false`, `max-body-bytes=5 MB` | `application.properties:125,158,162,167` | Filter is live. `bridge-mode` → §2. **`require-auth=false` is not benign here → §1b** |
| **`transferStock` returns HTTP 200 with an `errors` body on business failure**; `persistResponse` drops only non-2xx | `StockUnitController:127-130`; `RestIdempotencyService:192` | **A failed move would be cached as a success → §1a** |
| Retention job is **not** gated by `app.cron=false` — `@EnableScheduling` is unconditional in `SchedulingEnablementConfig` and the job is a plain `@Service` | `RestIdempotencyCleanupJob:26,48` | The 7-day window is real, not theoretical |
| `RestIdempotency` is a **tenant-PU** entity; routing key is `(tenant, facility)` | `net.aim_ai.wms.model` | Nonces cannot collide across tenants/facilities — no namespacing work |
| Endpoint under change | `StockUnitController:28` `@RequestMapping("/v3/stockUnit")` + `:68` `@PostMapping("/transferStock")` | The path is `/v3/stockUnit/transferStock` |
| UI call site | `wms2-mobile-ui store/moveStock.js:187-203` | `$post('/stockUnit/transferStock', data)`; `catch` collapses **every** error into one generic toast |

**No new table, no Flyway migration.** That retires the primary T3 escalation trigger from the parent
plan's §3.0 — confirmed by grounding, not assumed.

---

## 1. The decisive design constraint — auto-derive must NOT apply to `/v3`

Enrolling the path is one line. Getting the **key** wrong silently destroys real work.

A Move Stock double-submit sends a **byte-identical body** twice (same source stock unit, destination,
amount, comment). So `SHA-256(method|path|body)` produces the **same key** for both — meaning
auto-derive alone would dedupe the phantom-UL bug **with zero UI change.** That is the tempting design
and it must be rejected:

> A **deliberate** repeat move — an operator legitimately moving 12 more units from the same source to
> the same destination with the same comment — produces a byte-identical body too. Under auto-derive it
> is silently `REPLAYED`: the prior 2xx is returned, the UI shows "Stock moved", **and no second move
> happens.** For **7 days**, per the retention window.

That is a **silently dropped real move** — inventory-affecting in the opposite direction, and strictly
worse than the phantom unit loads this ticket is about. It is also already pinned as a requirement on
the client side: Slice 1's spec asserts *"a later, deliberate repeat move still goes through"*.

**⇒ For `/v3` the key must be an explicit client nonce, and the auto-derive fallback must be gated off.**
This is exactly what verify row `G1b` asserts, and the grounding above is the evidence for why it is the
right assertion rather than a stylistic preference.

**Corollary — scope must be an allow-list of the one exact path, never `startsWith("/v3/")`.** Measured:
**62** `@RestController`s, **52** under `/v3`; `AdminController:29` is `@RequestMapping("/v3")` with **43**
subclasses × **5 non-GET** methods, each re-registered per subclass prefix (`/v3/stockUnit/user/createUser`
is a live POST) ⇒ **~215 non-GET endpoints invisible to a mapping grep**, plus every business write across
the 52 controllers — `/v3/user/**` and `/v3/sysprop/**` included.

**Byte-identity verified, not assumed** (architect lane, Q1 — full evidence in
[[reviews/SBDEV-3003-slice2-review-architect]]): `scanDestination.vue:217-224` builds seven fields with
no timestamp, UUID or sequence, and a **partial** transfer decrements the source **in place** under the
same PK (`transferStockToUnitLoad:188`) — so a repeat move re-sends identical bytes. Only a *full*
transfer differs (source deleted → the repeat 404s). The replay is worse than silent: the store's
success branch fires on the cached `true`, so the operator sees a green **"Stock moved"** for a move
that never happened. ⚠ `wms2-web-ui` uses a **different key order** for the same intent
(`popups/transferStock.vue:100-107`), making the body hash client-serialization-dependent.

---

## 1a. HIGH — a *failed* move returns HTTP 200 and would be cached as a success

**Found by the architect lane; re-verified.** `StockUnitController:127-130`:

```java
if (errors.isEmpty()) { return ResponseEntity.ok(true); }
else { errorMap.put("errors", errors); return ResponseEntity.ok(errorMap); }   // 200 carrying a failure
```

Every business exception becomes a **200**, and `RestIdempotencyService:192` drops only non-2xx — so the
error body is persisted as the cached response. Two consequences, both worse than the phantom ULs:

1. **Retry after the cause is fixed → permanently stuck.** Locked destination → `200 {"errors":[…]}`
   cached under N1. `store/moveStock.js:196` resets only on success, so N1 stays live; after the
   supervisor unlocks it, the same body **REPLAYS** the cached failure forever.
2. **Correct the input → 409.** A different destination = same nonce, different body → `CONFLICT`, which
   per §3 the UI must *show*. The operator is stuck.

Known shape: `wms2-web-ui/cypress/…/transfer-offsite.cy.js:251` — *"the API returns 200 but doesn't move"*.

**⇒ Fix G-e + E-b (§4). Do not implement the rest without them** — without them this slice makes a failed
move unrecoverable.

---

## 1b. HIGH — the filter sits *upstream of authorization*, and `require-auth=false`

**Found by the architect lane; re-verified.** `/v3/**` is `hasAnyAuthority("wms_user")`
(`SecurityConfiguration:151`) but the filter is inserted after `BearerTokenAuthenticationFilter`
(`:160-162`) and `AuthorizationFilter` runs **last** — so the filter executes *before* the authority
check. With `require-auth=false` its own 401 gate (`IdempotencyFilter:120-128`) is skipped, so a POST
with **no `Authorization` header** reaches `doFilterInternal`; absent tenant headers then route the write
to the **landlord** DB (`TenantDynamicRoutingDataSource:51-54`) where `rest_idempotency` does not exist →
`42P01` → **500** instead of a clean 401.

`/rest/**` is `permitAll`, which is why `require-auth=false` was benign there; `/v3/**` is not. The
wiring comment at `:157-159` already states the invariant the property defeats — *"MUST run AFTER OAuth2
resource-server auth so unauthenticated callers cannot force tenant DB hits."* **⇒ Fix G-f (§4).**
Flipping `require-auth=true` later does **not** break the enrolled path.

---

## 2. Landmine — `bridge-mode` defeats the nonce

`RestIdempotencyService:147-162`: when `bridgeMode` is true, a **fresh, unique** key whose
`(requestHash, method, path)` matches **any** existing row returns `REPLAYED` — the ghost claim row is
promoted with the old response. So bridge-mode ON re-introduces §1's silent-drop **even with a correct
per-intent nonce.**

Default is `false` (`application.properties:162`) and its own javadoc says to disable it after Day+7 of
the SBDEV-2222 rollout, so it should be dead — but it is a property, and an env can carry a stale value.

**Requirement:** the `/v3` path must be immune to the bridge-mode branch regardless of the property, and
a test must pin that. Asserting "the property is false" is not sufficient — that is a config claim, not
a code guarantee.

---

## 3. The two 409s are not interchangeable

| Outcome | Body | Meaning | UI must |
|---|---|---|---|
| `REPLAYED` | cached **2xx** | The move already succeeded under this nonce | Nothing — the existing success path already works |
| `IN_FLIGHT` | 409 `idempotency-in-flight` | The first request is still running; the move **is** happening | **Suppress** the error toast (benign) |
| `CONFLICT` | 409 `idempotency-key-conflict` | Same nonce, **different** body — a real client bug | **Show** the error. Suppressing this hides a defect |

`store/moveStock.js:199-202` collapses everything into one generic network-failure toast, so a benign
in-flight 409 would today surface as a scary failure. Discriminate on `error.response?.data?.error`,
**not on the status code** — a blanket "suppress 409" is a defect, not the fix. That is the trap `G3`
exists to catch, and its previous version could not tell "suppresses the toast" from "logs the 409".

**Both prerequisites verified:** each 409 body is written with `setContentType("application/json")`
(`IdempotencyFilter:189-193`, `:218-222`) so `error.response.data.error` is readable; and
`plugins/axios.js:35-39` retries **only** 401/403, so neither 409 triggers a retry storm.

---

## 4. Fix design

**G-a — scope.** In `IdempotencyFilter.shouldNotFilter`, add an explicit allow-list containing exactly
`/v3/stockUnit/transferStock` (non-GET). Keep the existing `/rest/` behaviour untouched.

**G-b — key policy per scope.** Auto-derive (`:175`) stays for `/rest/**`. For an allow-listed `/v3`
path, a **missing or blank `Idempotency-Key` must not auto-derive.** Decide and record which:

- **(i) fall through undeduped — fail open. Recommended**, matching Q1's resolution; a legacy client
  (an older mobile build in the field) keeps working, unfixed.
- (ii) reject `400 missing-idempotency-key` — stronger, but hard-breaks any caller without the nonce.

Warehouse app versions lag server deploys, so (i) is the safer default and still fixes every client
that sends the nonce. Confirm the choice here before implementing.

**G-c — bridge-mode immunity.** The bridge-mode branch must not run for allow-listed `/v3` paths (§2).

**G-d — counter.** One Micrometer counter incremented on `REPLAYED`/`IN_FLIGHT`, tagged by path and
outcome. **Put it in `RestIdempotencyService`, not the filter** — and this is now **proven by
compilation, not argued**:

| Shadow | Counter location | `mvn clean compile` |
|---|---|---|
| `correct2` | `IdempotencyFilter` | **BUILD FAILURE** — `SecurityConfiguration:161 cannot find symbol: variable meterRegistry` |
| `correct3` | `RestIdempotencyService` | **BUILD SUCCESS**, `SecurityConfiguration` untouched |

The filter is `new`-ed in `SecurityConfiguration:160-162` and is *not a Spring bean*, so a
`MeterRegistry` has to be threaded through the security config — and the moment you add the
constructor argument without also injecting the bean, the build breaks. The service is a `@Service`,
sees every `ClaimResult` at `tryClaim`'s returns, is registry-assertable in the existing
`RestIdempotencyServiceUnitTest`, and yields a `/rest/**` baseline for free. **This is the only genuinely new backend logic in the slice**, and `G2` previously had the
weakest row in the file (satisfied by a `// TODO duplicateTransfer counter` comment).

**G-e — never cache a failure as a success (§1a).** On an allow-listed path, a 2xx whose body carries an
`errors` key must **not** be persisted as the cached response. Code-level, not client-dependent — the
same standard §2 applies to bridge-mode. Verify row + mutation check.

**G-f — require authentication in code for allow-listed paths (§1b).** Independent of
`app.idempotency.require-auth`. Free: the path already requires `wms_user`. This is the inverse of §2's
requirement and rests on the same argument — a config value is not a code guarantee.

**E — client nonce (`wms2-mobile-ui`).** One nonce **per operator intent**, and the requirement is that
it *survives an operator re-tap and a component re-mount* — **not** "survives a transport retry": there
is no such retry. `plugins/axios.js:35-39` retries only 401/403 and returns `false` for
`!error.response`, the timeout case. A Jest test asserting "reused across a retry" would pin a
token-refresh path, not this scenario.

- Mint at payload-build time in `store/moveStock.js`, hold in module state, send as `Idempotency-Key`.
- **Never put it on `config.headers.common`.** `plugins/axios.js:126-155` puts
  `Authorization`/`X-Tenant-ID`/`facility_code` on shared defaults; a nonce there leaks into every later
  request, so the *next* transferStock reuses a stale nonce → REPLAYED or CONFLICT. This is the
  SBDEV-2726 bug class in the same file. Per-request only.
- **E-b (§1a):** clear or re-mint the nonce on the `results.errors` branch too
  (`store/moveStock.js:193-195`), not only on success — otherwise a fixed-and-retried move is
  permanently stuck.
- Charset must satisfy `[A-Za-z0-9_\-]{1,64}` (`IdempotencyFilter:69`). **`crypto.randomUUID()` is not
  unconditionally available** — zero uses across both UIs, no `uuid`/`nanoid` dependency, and it
  requires a *secure context*: on a handheld WebView over plain HTTP or an older Android WebView it is
  `undefined` → `TypeError` inside `submit()` → **the move never fires at all**. Specify
  `crypto.randomUUID?.() ?? <hex from crypto.getRandomValues> ?? <last-resort>` and cover the fallback
  branch in Jest (jsdom may not expose it either).
- Discriminate the two 409s per §3.

**Not in scope:** `StockunitService:192` (a new unit load per request) stays as-is — parent plan Q1
rejected merge-into-existing-UL, and verify row `E1` was deleted for asserting a design that was
rejected. Dedupe is the fix; merging is not.

---

## 5. Testing

**Correction (architect lane, H2): a unit test CAN catch a filter-scope regression.** Draft r1 claimed
otherwise and built its whole strategy on that. `src/test/java/net/aim_ai/wms/unit/landlord/IdempotencyFilterUnitTest.java`
(22 KB) already drives the filter through its **public** entry point — `MockHttpServletRequest` +
`filter.doFilter(req, resp, chain)` + `verify(chain, never())`, 12 call sites — and
`OncePerRequestFilter.doFilter` consults `shouldNotFilter` before delegating. So the scope gate is
already covered end to end with no Spring context. **Extend that test in place**; do not relocate
anything, and do not test `protected shouldNotFilter` directly — that would go green even if
`doFilterInternal` ignored scope entirely.

**Automated (required):**
1. Scope, via `filter.doFilter`: allow-listed path → `verifyNoInteractions(chain)` + claim attempted; a
   **different** `/v3` POST → `verify(chain, times(1))` **and** `verifyNoInteractions(idempotencyService)`
   — that second half is what makes the allow-list-vs-prefix assertion non-vacuous; GET on the
   allow-listed path → out; `/rest/**` unchanged; `enforce=false` → out.
2. Key policy: header present → used; absent on the allow-listed path → **no auto-derived key** (§1 pin);
   absent on `/rest/**` → still auto-derived.
3. Bridge-mode immunity with `bridgeMode=true` (§2).
4. **G-e:** a 2xx whose body carries `errors` is **not** cached (§1a).
5. **G-f:** no `Authorization` header on the allow-listed path → refused before any DB call (§1b).
6. Counter incremented — assert the **registry**, not a string in the source.
7. Jest: nonce minted once per intent and stable across a re-tap **and a component re-mount**; cleared
   on success **and** on the `errors` branch; never on `headers.common`; `randomUUID` fallback exercised;
   in-flight 409 suppressed; key-conflict 409 **surfaced**.

**Manual curl matrix on DEV (still required)** — only it covers Spring Security ordering and the real
filter chain. Against a real tenant, checking `unitload` row counts after each:

| # | Request | Expect |
|---|---|---|
| 1 | single transfer, nonce N1 | 200, **1** new UL |
| 2 | nonce N1 twice, concurrent | one 200 + one 409 `in-flight`, **1** UL |
| 3 | nonce N1 twice, sequential | 200 then replayed 2xx, **1** UL |
| 4 | **nonce N2, identical body** | 200, **2** ULs — the deliberate repeat must work (§1) |
| 5 | nonce N1, different body | 409 `key-conflict` |
| 6 | **no header on the allow-listed path** | per G-b(i): proceeds undeduped — **no** auto-derived key |
| 7 | **an unrelated `/v3` POST** | unaffected, no dedupe row written |
| 8 | **no `Authorization` header** on the allow-listed path | clean 401/403 — **not** a 500, and no landlord-DB write (§1b) |
| 9 | nonce N1 on a move that **fails** (locked destination), then re-submit after unlocking | second attempt **executes** — not a replayed failure (§1a) |

Rows **4, 6, 7, 8 and 9** catch the catastrophic designs; 1–3 only prove the happy path.

## 6. Acceptance — **all four existing rows are measured untrustworthy**

**Row-discrimination lane COMPLETE** (18 shadows, zero unrelated-row drift, the real script never
edited — `md5 a0083a5990f6d1846304fc14d2b1a6e1`). Full record + replacement row code:
[[reviews/SBDEV-3003-slice2-row-discrimination]]. Verdict:

> **None of `G1`, `G1b`, `G2`, `G3` can be trusted. All four go green on a correct implementation
> AND on implementations broken in exactly the ways this plan says matter most.
> 12 of 16 broken shadows scored `39 pass, 0 fail, 3 skip` — a FULL GREEN, indistinguishable from
> correct.**

| Row | Measured failure |
|---|---|
| `G1` | Bare unanchored substring, no comment exclusion. A `// TODO` comment greens it with `shouldNotFilter()` untouched (`B3`/`B3b`); and **`"/v3/stockUnit/transferStockToUnitLoad"` contains the searched string**, so enrolling the WRONG endpoint reads as success (`B8`) — and `transferStockToUnitLoad` is a real symbol in `StockunitBusinessService`, so that confusion is live, not contrived |
| `G1b` | **Anti-correlated with correctness.** It requires one of five hard-coded identifiers after `sha256HexComposite`; in `B2` the counter guard `if (v3Scope)` in the REPLAYED branch supplies the token while auto-derive stays **completely ungated** — the row's entire stated purpose, unmet. And renaming the boolean false-REDs a fully correct build (`C2`, `dedupeEnrolled`) |
| `G2` | Gap is unbounded, so it means "name somewhere, `MeterRegistry` somewhere later". `B4` (`.increment()` deleted) and `B4b` (incrementing on `CLAIMED`, inverting the metric) are both green. **`B3b` proves the TODO trap the row was rewritten to close is still open** — `B3` only stayed red by accident of the comment's word order |
| `G3` | Any mention of the header plus any mention of 409 in the same action. Misses `B5` (blanket 409 suppression — the exact defect §3 names), `B6` (per-attempt nonce), `B10` (base64 nonce the filter 400s before dedupe), `B17` (nonce cleared in `finally`). Caught only the shadow that does nothing at all |

### ADOPTED 2026-08-20 — the four rows are replaced by twelve

Nam accepted the replacements. The lane measured them in a standalone harness, so **they were
re-measured inside the real script after adoption** — the integration is a different thing from the
draft, and a row that only works in its author's harness is not a row:

| Shadow (real script, `SKIP_MVN=1`) | `Result:` | Rows red |
|---|---|---|
| real worktrees (pristine) | `37 pass, 10 fail, 3 skip` | the 10 progress rows; `G1c`/`G3d` green as designed |
| **`correct`** | **`47 pass, 0 fail, 3 skip`** | none |
| **`C2` renamed, still correct** | **`47 pass, 0 fail, 3 skip`** | none — **the old `G1b` false red is gone** |
| `B1` prefix scope | `45 pass, 2 fail` | `G1`, `G1c` |
| `B2` auto-derive ungated | `45 pass, 2 fail` | `G1b`, `G1d` |
| `B8` wrong path enrolled | `45 pass, 2 fail` | `G1`, `G1c` |
| `B15` prefix-match on full path | `46 pass, 1 fail` | `G1c` |
| `B16` wrong branch condition | `46 pass, 1 fail` | `G1d` |
| `B4` counter never incremented | `46 pass, 1 fail` | `G2` |
| `B4b` counter on wrong outcome | `46 pass, 1 fail` | `G2b` |
| `B7` bridge mode still applies | `46 pass, 1 fail` | `G4` |
| `B3b` comment-only, reordered | `40 pass, 7 fail` | `G1`, `G1b`, `G1d`, `G2`, `G2a`, `G2b`, `G4` |
| `B5` UI blanket 409 | `46 pass, 1 fail` | `G3b` |
| `B6` UI nonce per attempt | `46 pass, 1 fail` | `G3c` |
| `B17` UI nonce cleared in `finally` | `46 pass, 1 fail` | `G3c` |
| `B10` UI base64 nonce | `46 pass, 1 fail` | `G3d` |

Every broken shadow is caught by exactly the row predicted, and both correct variants are fully green.
Two new shared helpers (`code_contains` / `code_not_contains`) strip comment lines before matching,
closing the "a TODO satisfies the row" class for positive *and* negative rows.

**`G1c` and `G3d` are GUARD rows** — they pass on the pristine tree and are exempt from the all-red
baseline (joining `P1`–`P3`). A green `G1c` alone does **not** mean the allow-list is right; it is only
meaningful paired with `G1`, the progress row. Both facts are printed in the script's closing reminder.

### G-e and G-f now have rows too — `G5` and `G6`, added and mutation-checked 2026-08-20

The two architect Highs were the last uncovered part of the row layer. Six new shadows were built on
top of the lane's `correct` implementation and both rows measured against all of them:

| Shadow | `Result:` | `G5` | `G6` |
|---|---|---|---|
| **`correct2`** — G-e + G-f implemented | **`49 pass, 0 fail, 3 skip`** | PASS | PASS |
| `correct` / `C2` — Slice 2 without G-e/G-f | `47 pass, 2 fail` | FAIL | FAIL |
| `Be1` — comment-only TODO naming both fixes | `47 pass, 2 fail` | FAIL | FAIL |
| `Be2` — detects the errors body, only **logs** it | `48 pass, 1 fail` | **FAIL** | PASS |
| `Be3` — errors check **not scoped** (would change `/rest/**` too) | `48 pass, 1 fail` | **FAIL** | PASS |
| `Bf1` — auth gate left as `if (requireAuth)` | `48 pass, 1 fail` | PASS | **FAIL** |
| `Bf2` — gate widened by an **unrelated** condition (`\|\| enforce`) | `48 pass, 1 fail` | PASS | **FAIL** |

Each row reds **only on its own axis's mutants** and stays green on the other's — the axis separation
that the old `G1b` lacked. Both use a **backreference to the scope declaration**, so a rename stays
green (`C2`-style) while a gate widened by an unrelated condition still reds.

**Two bugs in these rows were caught by the measurement, not by review** — both would have produced a
permanently-red row indistinguishable from unfinished work, and both are annotated in the script:

1. `(?i:errors)` is required. The operand is normally a **constant** (`CARRIES_ERRORS`), so a
   case-sensitive `errors` false-REDDED the correct implementation.
2. `\\?"errors` is required. Inside a Java string the key is written `\"errors\"`, so a bare
   `'"errors"'` pattern **cannot** match (quote, `errors`, **backslash**, quote) — measured at 0 hits.

A third was caught in my own scratch diagnostic rather than the row: it reported `Be1` as having the
auth fix, because `Be1`'s TODO comment *contains the literal* `(requireAuth || v3Scope)`. That is
exactly the trap `code_contains_ml` exists to close, and it appeared in the first tool written to check
for it — evidence for keeping comment-stripping the default rather than an option.

### The row layer scored 49/0 on code that does not compile — and the counter rows contradicted the plan

`mvn clean compile` was run on the `correct2` shadow (the request that produced this section) and it
**failed**. Two findings, both material:

1. **`correct2` does not build.** `SecurityConfiguration:161` passes `meterRegistry` to the filter's
   new constructor argument, and nothing injects it. **The row layer had scored that same tree
   `49 pass, 0 fail, 3 skip` — a full green on code the compiler rejects.** This is the row lane's own
   §7.5 item 5 landing in practice, and it is the argument for `mvn clean compile` being a floor item
   rather than a closing formality: greps grade what was *written*, never what *builds*.
2. **Rows `G2`/`G2a`/`G2b` graded the wrong file.** All three asserted against `IdempotencyFilter`
   while §4 G-d says the counter belongs in `RestIdempotencyService` — so implementing the plan as
   written would have redded them. That is exactly the "satisfiable only by writing code in the wrong
   place" defect the original `G1` had on this ticket, reappearing in a row that had already survived
   one adversarial pass. **Retargeted to `$V2_RIS`, and `G2b` rewritten** for the service's `tryClaim`
   return paths, with a third NEGATIVE conjunct forbidding a count before `return ClaimResult.CLAIMED`.

Re-measured on a coherent `correct3` family (counter in the service, `SecurityConfiguration` pristine):

| Shadow | `Result:` | Red |
|---|---|---|
| **`correct3`** | **`49 pass, 0 fail, 3 skip`** + **BUILD SUCCESS** | none |
| `B4p` counter registered, never incremented | `48 pass, 1 fail` | `G2` |
| `B4bp` counter increments on `CLAIMED` | `48 pass, 1 fail` | `G2b` |
| `Be1p` comment-only TODOs for G-e and G-f | `47 pass, 2 fail` | `G5`, `G6` |
| `Be2p` detects the errors body, only logs | `48 pass, 1 fail` | `G5` |
| `Be3p` errors check unscoped | `48 pass, 1 fail` | `G5` |
| `Bf1p` gate left as `if (requireAuth)` | `48 pass, 1 fail` | `G6` |
| `Bf2p` gate widened by `\|\| enforce` | `48 pass, 1 fail` | `G6` |

The scope/key/bridge/client axes were re-confirmed on the original shadows and still discriminate
exactly: `B1`/`B8` → `G1`+`G1c`; `B2` → `G1b`+`G1d`; `B15` → `G1c`; `B16` → `G1d`; `B7` → `G4`;
`B5` → `G3b`; `B6`/`B17` → `G3c`; `B10` → `G3d`. (Those shadows also red the counter rows now, an
expected artifact — they predate the relocation and keep their counter in the filter.)

**Live baseline is now `37 pass, 12 fail, 3 skip`** against the real worktrees (14 Slice 2 rows: 12 red
progress rows + `G1c`/`G3d` green guards). The 35 Slice 1 rows are unaffected.

⚠ **Live hole the lane flagged (its §7.5 item 3): no row, current or proposed, covers §5's unit tests.**
Every residual blind spot in the row layer is delegated to exactly those tests, so if they are skipped
nothing catches the gap. And nothing here was compiled or executed — all 19 runs were `SKIP_MVN=1`, no
filter chain booted, no counter read from a registry, no DB touched. `mvn clean compile` and the §5 curl
matrix remain mandatory, not optional.

## 6a. TDD gate record (2026-08-20) — 6 reds, all for stated reasons

**Branch** `bugfix/SBDEV-3003-slice2-transfer-stock-idempotency` @ **`45bcf33`**, off freshly-fetched
`origin/develop` (`60aef02`). Mobile: `bugfix/SBDEV-3003-slice2-move-stock-nonce` off `7f83d55`.
Slice 1's worktree is untouched and still on its own branch under PR review — **not stacked**.

| Suite | Result |
|---|---|
| `IdempotencyFilterUnitTest` | **21 run, 4 failures, 0 errors** |
| `RestIdempotencyServiceUnitTest` | **9 run, 2 failures, 0 errors** |
| Full suite | **5232 run, 8 failures** — the 6 gate reds + the 2 known pre-existing develop failures (`OptionalSafetyArchTest#noNewOptionalGetCallsInServiceClasses`, `MobilePalletizingServiceTest#testScanParcelBulkPalletAlreadyAssignedToGate`) |

| Red | Fails because |
|---|---|
| `dedupe_when_pathIsAllowListed` | "zero interactions with this mock" — path not enrolled |
| `notCache_when_2xxCarriesErrorsBody` | `persistResponse` never invoked |
| `cache_when_2xxIsGenuineSuccess` | `persistResponse` never invoked |
| `refuseAnon_onAllowListedPath_…` | **expected 401 but was 200** — the anonymous POST sails through; this red *is* §1b |
| `ignoreBridgeRow_when_suppressed…` | **expected CLAIMED but was REPLAYED** — a fresh unique nonce replayed off another nonce's row; this red *is* §2 |
| `countDuplicate_when_replayed…` | expected 1.0 but was 0.0 — no counter registered |

**4 tests labelled `[pin: vacuous pre-fix]`** — the out-of-scope `/v3` sibling, GET on the
allow-listed path, `enforce=false`, and G-b's fail-open. They pass today only because nothing is
enrolled, so "no interaction with the service" is trivially true. Meaningless alone; load-bearing
only paired with `dedupe_when_pathIsAllowListed`. **Each owes a mutation check at implementation**,
and the mutant that must red it is named on the test. Two regression guards pass genuinely and must
keep passing: `/rest/**` still auto-derives a 64-hex key, and `/rest/**` anonymous behaviour is
unchanged under `require-auth=false`.

### Three implementation constraints the gate discovered

1. **G-c must be an OVERLOAD, not a widened signature.** There are **33** existing `tryClaim(...)`
   call sites across the two test classes; widening the 4-arg signature breaks every one at compile
   time for no behavioural gain.
2. **No `IdempotencyFilter` constructor change is needed at all** — a direct consequence of moving
   the counter to `RestIdempotencyService`. Micrometer is already a dependency
   (`micrometer-registry-prometheus`), so no pom change either.
3. **API surface had to be added to `src/main` at the gate** (the overload, ignored; the
   `MeterRegistry`, unused) so the tests fail *behaviourally*. A test that does not compile blocks
   the whole module and reads as unfinished work rather than as a red — the same failure class as a
   verify row that shells out to a missing command.

**Not yet done:** the client-side Jest gate (Fix E) in the mobile worktree, and every item in §5's
curl matrix. `RestIdempotencyServiceUnitTest` is confirmed to exist and is the right home for the
counter assertion, exactly as architect L1 predicted.

---

## 6b. Implementation record (2026-08-21)

**Commits.** `wms2-api` **`a8e2997`** on `bugfix/SBDEV-3003-slice2-transfer-stock-idempotency`
(1 commit ahead of `origin/develop` `60aef02`, on top of the gate `45bcf33`);
`wms2-mobile-ui` **`ef54f57`** on `bugfix/SBDEV-3003-slice2-move-stock-nonce` (1 ahead of `7f83d55`).
Not stacked on Slice 1 — whose v2 PRs (api #175, mobile-ui #39) are still **open**, so
`origin/develop` is unchanged on both repos. The parent plan's "MERGED" refers to the **v1** repos.

**Results.**

| Gate | Baseline (gate, 45bcf33) | After |
|---|---|---|
| `mvn clean compile` | — | **BUILD SUCCESS** |
| `IdempotencyFilterUnitTest` | 21 run, **4 failures** | **22 run, 0 failures** |
| `RestIdempotencyServiceUnitTest` | 9 run, **2 failures** | **9 run, 0 failures** |
| api full suite | 5232 run, 8 failures | **5233 run, 2 failures** — exactly the two known pre-existing develop failures |
| mobile Jest, new spec | 13 run, **9 failures** | **13 run, 0 failures** |
| mobile Jest, full | — | **169 passed, 11 suites, 0 failures** |
| verify script, 14 Slice 2 rows | 12 red + 2 green guards | **all 14 PASS** |

`OptionalSafetyArchTest`'s 6 violations are all in files this slice never touched
(`MobileReplenishService`, `PickLineRealignmentService`, `ReplenishGeneratorService`,
`UnitloadBusinessService`). `mvn test` mutated the tracked `archunit_store` fixture as always;
reverted before committing.

### Mutation checks — 16 mutants, each red on exactly the predicted assertion

| # | Mutant | Red |
|---|---|---|
| M-a | prefix scope instead of exact match | `notDedupe_when_otherV3Path` |
| M-b | GET gate removed | `notDedupe_when_getOnAllowListedPath` |
| M-c | enforce gate removed | `notDedupe_when_enforceFalse` |
| M-d | fail-open branch deleted (auto-derive ungated) | `failOpen_when_noHeaderOnAllowListedPath` |
| M-e | G-f gate narrowed back to the property | `refuseAnon_onAllowListedPath_whenRequireAuthFalse` |
| M-f | G-e errors check unscoped | `stillCacheErrorsBody_when_restPath` |
| M-g | bridge suppression ignored | `ignoreBridgeRow_when_suppressedForAllowListedPath` |
| M-h | counter never incremented | `countDuplicate_when_replayed_butNotWhenClaimed` |
| M-i | counter also fires on `CLAIMED` | same test, second assertion |
| M-j | 4-arg overload suppresses bridge mode too | `tryClaim_bridge_mode_replays_uuid_keyed_row` (C3) |
| C-a | nonce written to `headers.common` | `never writes onto the shared axios defaults` |
| C-b | nonce moved into Vuex state | `keeps the nonce out of Vuex state` |
| C-c | nonce minted per attempt | `reuses the SAME nonce on a re-tap` |
| C-d | blanket `status === 409` suppression | `SHOWS the error for key-conflict` |
| C-e | nonce cleared in a `finally` | `reuses the SAME nonce on a re-tap` |
| C-f | `randomUUID` called unguarded | both fallback cases |
| C-g | E-b removed (nonce kept on the errors branch) | `re-mints on the results.errors branch` |

### Four things the measurement found that review had not

1. **A gate pin was VACUOUS EVEN AFTER THE FIX.** Mutant M-b (GET gate deleted) scored **21/21
   GREEN**: with the gate gone the request is in scope but header-less, so it took G-b's own
   fail-open branch and "no interaction with the service" stayed trivially true. The two fixes
   interlocked to hide each other. Closed by sending a nonce on the GET.
2. **Nothing pinned that G-e is SCOPED.** Mutant M-f (the `v3AllowListed` conjunct dropped) also
   scored 21/21 green — verify row `G5` catches it but no test did. A new regression test asserts
   `/rest/**` still caches an errors-shaped 2xx, which is the OMS contract.
3. **§5's "extend `IdempotencyFilterUnitTest` in place" was right, but the drafted G-a test
   contradicted verify row `G4`.** The test stubbed and verified the **4-arg** `tryClaim` on the
   allow-listed path; `G4` requires the **filter** to pass the suppression flag
   (`tryClaim(…bodyHash, !…)`). Only one could hold. Resolved in favour of passing the flag — the
   alternative duplicates the allow-list into the service — and the verify is now strictly
   stronger, pinning suppression at the call site as well as scope. The 4-arg overload stays the
   `/rest/**` contract, so the 11 pre-existing `/rest` tests were untouched (which also avoids a
   false-green class: two of them are `verify(service, never()).tryClaim(4-arg)`, which would go
   vacuous if the filter always called the 5-arg form).
4. **The client success branch released the nonce only via the `initialize` mutation it commits.**
   Found because the Jest harness mocks `commit`. That coupling is real, not a test artefact: a
   caller that skips the commit, or a throw between the two commits, carries the nonce into the
   next intent. Now released explicitly in the action too.

### Row-layer defects found while implementing

- **`G3` requires the header object INLINE in the `$post` call.** Its regex demands the order
  `$post('/stockUnit/transferStock'` → `headers` → `Idempotency-Key`, so hoisting the config into
  a `const` above the call — which is what the plan's §4 wording suggests — reds a correct
  implementation. Inlined; worth loosening the row rather than constraining the code next time.
- **`G3c`'s second conjunct is VACUOUS.** It requires `initialize(state) { … \w+ = null }`, which
  the pre-existing `state.currentStockInfoDto = null` already satisfies. The nonce clear was added
  there anyway (it is the right intent boundary), but that conjunct proves nothing.
- **`G5`'s second conjunct is proximity-bounded at `[^}]{0,200}`,** so a log line placed between
  `if (flag) {` and `effectiveStatus =` reds it — and a `{}` placeholder in the log format string
  breaks the `[^}]` class outright. The assignment must come first. This is the
  "proximity regexes secretly assert same-block" class again.

**Still owed, none of it machine-knowable:**

1. **The §5 curl matrix on DEV, all 9 rows.** Nothing in this implementation booted a filter chain,
   read a counter from a live registry, or touched a database — every run was unit-level. Only the
   matrix covers Spring Security ordering and the real chain. Rows **4, 6, 7, 8, 9** are the ones
   that catch the catastrophic designs.
2. **The per-environment CORS pre-deploy check** for the `Idempotency-Key` preflight (§7). Neither
   curl nor the DevTools Network panel reliably verifies this in this repo.
3. **One independent code review.** Both T2 lanes ran *before* implementation; this diff has not
   been reviewed by anyone but its author.
4. **Manual QA on a handheld**, including the `randomUUID`-absent path on a plain-HTTP WebView.

---

## 6c. Independent implementation review (2026-08-21) — 1 High, 7 Medium, 8 Low, all addressed

Two lanes, neither of which wrote the code. Full records:
[[reviews/SBDEV-3003-slice2-review-api-impl]] · [[reviews/SBDEV-3003-slice2-review-client-impl]].

**Both lanes independently confirmed the central design and the six sub-fixes.** Neither found an
authz bypass, a data-integrity defect, or a way to cache a failed move as a success. What they did
find was that **six of my assertions were vacuous** — measured, not argued — including two protecting
the most consequential branches in the change. Everything below is now fixed and mutation-checked.

### The High

**H1 — silent in-flight suppression × the server's 60-second stale-claim reclaim = a duplicated move
with no operator feedback at any point.** Three facts, each recorded in a *different* section of this
plan and never joined: §3 says suppress the in-flight toast; §7's fourth residual says
`RestIdempotencyService` re-claims a `102` row after 60 s; and `plugins/axios.js` sets **no client
timeout** at all. So on a slow or hung transfer the operator gets *nothing* — no error, no spinner
resolution, no screen change — re-scanning is the natural handheld response, each re-scan is silently
swallowed, and **the first re-tap past the 60 s mark performs a second real move**. That is this
ticket's own symptom, reached through its fix. Under an indefinite hang (a documented class in this
repo) every subsequent 60 s window admits one more move.

Fixed two ways: an **in-flight latch** in module state beside the nonce, so the second dispatch never
reaches the network and the 60 s window is never entered; and **non-error feedback**
(`$toast.info`) — suppressing the *error* toast was the requirement, suppressing *all* feedback was
not. The latch is released when the request settles, and at both intent boundaries, which is the
operator's escape hatch from an indefinitely hung request (whose `finally` never runs).

### Medium

| # | Finding | Fix |
|---|---|---|
| **F1** | The counter's `path` tag is a **client-chosen string** on the `/rest/**` half of its reach: `shouldNotFilter` admits any `/rest/**` URI mapped or not, `/rest/**` is `permitAll`, and two concurrent identical POSTs return `IN_FLIGHT`. **Measured: 500 junk paths → 500 distinct meters**, retained for the process lifetime and scraped by Prometheus. My javadoc asserted the opposite. | Bounded label whitelist → `other`. Explicitly documented as a *metric label* set, not a second scope gate; an unlisted path costs a label, never correctness. |
| **F2** | **G-f gated on authentication where the threat model needs authorization.** `/v3/**` requires `hasAnyAuthority("wms_user")` and `AuthorizationFilter` runs last, so a principal with a valid default-issuer JWT and *zero* WMS authorities still reached `tryClaim` — a pre-authz tenant write — and with no tenant headers still hit landlord → `42P01` → **500**, where they previously got a clean 403. **The exact failure §1b claims G-f closes was still reachable, one rung up the ladder.** | Authority check on the enrolled path → 403. Introduced `Authority.WMS_USER_ROLE` and pointed *both* `SecurityConfiguration` route rules and the filter at it — a stale second copy of that string would fail CLOSED and refuse every real move. |
| **F3** | The fail-open assertion used `mock(FilterChain.class)`, which never reads the body — so a mutant passing the **original, already-drained** request through scored **22/22 green**. That mutant 500s every nonce-less transfer, i.e. it breaks exactly the legacy-handheld case G-b exists to preserve. | Chain lambda that reads the body and asserts it round-trips. |
| **M1** | Nothing pinned that the in-flight branch must **not** release the nonce — the single most load-bearing line in the client diff. Mutant: 13/13 green, and it duplicates a move on the very next re-tap with no 60 s wait. | Assertion added. |
| **M2** | The whole `idempotency-key-conflict` branch was unpinned: **deleting it outright left 169/169 green**, because the generic fallback also calls `toast.error`. | Assert the specific copy and the nonce release. |
| **M3** | Mutant removing the nonce clear from `resetState` → 169/169 green. That is the *only* boundary covering "operator abandons the screen after a transport failure, leaves the page, re-enters". Its `initialize` twin *was* pinned. | Assertion added. |
| **M4** | Mutant deleting `initialize` + `setProcess('1_select')` from the success branch → 169/169 green — in a branch this fix restructured. | Assertion added. |

### Low

**F4** the diverted 500 reaching the client was unpinned (mutant 22/22 green) — it would render every
business failure as a generic network toast, hiding the real reason; now asserts the client still gets
200 + the message. **F5** `carriesErrors` is a raw case-sensitive substring test — correct for today's
handler (the only 2xx success body is the literal `true`), now carries a comment saying so and what to
switch to if that DTO changes. **F6** `getRequestURI()` is **undecoded** while Boot 3 matches the
decoded path, so `/v3/stockUnit/transfer%53tock` reaches the handler and misses the allow-list —
harmless while G-b fails open, load-bearing the moment G-b is tightened to reject-400; recorded in the
allow-list javadoc. **F8** the `SIBLING` test constant's comment overstated it (a service symbol, not
a mapped endpoint). **L1** the conflict message gave advice the operator does not need and was
factually wrong after an offline first attempt; reworded. **L2** `Math.random().toString(36).slice(2, 12)`
yields fewer than 10 chars when the float's base-36 expansion is short (empty at exactly 0); two draws
now. **L3** `Array.from`(mapFn)/`padStart` are polyfilled by Nuxt 2's default babel preset today, but
that is a build-config accident — and the mint runs *inside* the action's `try`, so a `TypeError` was
swallowed into the generic network toast and the move silently never fired, the very failure the
fallback chain exists to prevent; the generator can no longer throw. **L4/M5** the `keep-alive` trap
(if one is ever added around these pages, `created()` stops firing and the nonce **would** leak across
intents — the SBDEV-2930 trap) and the page-vs-component re-mount distinction are now stated
accurately in the code rather than overclaimed.

### Verification after the review fixes

13 further mutants, each red on exactly the intended assertion: R-F1, R-F1b, R-F2, R-F2b, R-F3, R-F4
on the api side; R-M1, R-M2, R-M7, R-M4, R-M5b, R-H1 on the client. All six that the reviewers had
measured **surviving** are now killed. `IdempotencyFilterUnitTest` 25/0,
`RestIdempotencyServiceUnitTest` 11/0, full mobile suite **176/176**, all 14 verify rows still green.

### Recorded, deliberately NOT fixed here

- **`POST /v3/stockUnit/bulkTransferStock`** (`StockUnitController:135`) runs the same
  `transferStock` in a loop and is not enrolled. Mobile-only is this slice's design (§4), and the web
  UI serialises the same intent in a **different key order**, so auto-derive could never cover it
  either. Per the ticket policy this is recorded here rather than filed.
- **Valid token + missing tenant headers → landlord routing → 500** remains reachable for a caller
  who *does* hold `wms_user`. Not widened into a second gate: curl-matrix **row 8** is where this
  belongs, and a second in-filter guard duplicating routing rules is the stale-copy hazard F2's fix
  was careful to avoid.
- `wms2-web-ui` as an uncovered second caller — unchanged from §7.

---

## 6d. Merge, deploy, and the curl matrix (2026-08-21)

### Merged — all four PRs on this ticket

| Repo | Slice 1 | Slice 2 |
|---|---|---|
| `wms2-api` | #175 → `7c23646` | **#176 → `cdd85d9`** |
| `wms2-mobile-ui` | #39 → `682c015` | **#40 → `55435bf`** |

**The combined state was tested before anything was merged**, because no individual PR's CI checks it:
Slice 1 + Slice 2 were trial-merged into throwaway worktrees off `origin/develop` and the full suites
run — api **5238 run, 2 failures** (exactly the two known pre-existing develop failures), mobile
**188/188, 12 suites**. Zero file overlap in either repo, so the merges were conflict-free; the mobile
pair does interact behaviourally (Slice 1's `await` + component `submitting` flag vs Slice 2's store
latch) and they compose as belt-and-braces. Both merges then verified with
`git merge-base --is-ancestor`, not by reading the PR page.

### A deploy race worth knowing about

`.github/workflows/docker-image-develop.yml` fires on every push to `develop`, builds
`hub.impactathleticsny.com/wms2-api:develop`, and POSTs **two portainer webhooks** to redeploy DEV.
Merging two PRs minutes apart starts **two builds against different commits that both push the same
tag** — and #175's tree does **not** contain Slice 2. Had that build finished last it would have
overwritten the image with one lacking the fix, while every PR page still read "merged".
Measured: #175's build finished 13:33:12, #176's 13:33:23, so the correct image won. **Do not rely on
that ordering** — verify behaviourally, as below.

### Deployment confirmed behaviourally, not inferred

`/actuator/info` exposes only JVM info on this host — **it cannot tell you which commit is live**
(`app.version` is set as a property but not contributed to the endpoint). The usable discriminator
needs no credentials and is the response *shape* of an unauthenticated POST to the enrolled path:

| | status | `www-authenticate` | who answered |
|---|---|---|---|
| before the merge | 401 | **present** | Spring's `BearerTokenAuthenticationEntryPoint` — the filter was never in scope |
| after the redeploy | 401 | **absent** | `IdempotencyFilter`'s own G-f gate, which sets the status and returns |

⚠ **Requiring only the header's absence is a false-green.** My first probe read a **502** (container
mid-restart) as "deployed", because a 502 carries no `www-authenticate` either. Gate on
`status == 401 AND no www-authenticate`, and wait for `/actuator/health` to report `UP` first.

### Matrix rows PASSED on live DEV

| Row | Result |
|---|---|
| **0** deployment discriminator | PASS — 401, no `www-authenticate` |
| **8** no `Authorization` on the enrolled path | **PASS — 401, not a 500.** This is the row that would have surfaced review F2, and the one §1b is about |
| **7** scope half — `/v3` siblings unaffected | **PASS, and this is the strongest single result.** The enrolled POST path is the ONLY path in filter scope. Seven other `/v3` POSTs are all out of scope: `transferStockToUnitLoad` (the substring-superset trap), `bulkTransferStock`, `stockUnit/user/createUser` (an `AdminController`-inherited route), `sysprop/save`, `user/save`, `userRole/delete/1`, `adminAction/run`. The exact-match allow-list is confirmed on the running server and the ~215-endpoint prefix hazard is retired **empirically**, not by argument |
| GET on the enrolled path | PASS — out of scope. Worth noting: this is the very pin whose mutant scored **21/21 green** in unit tests, so live confirmation is the first real evidence for it |

### Rows BLOCKED — credentials, not effort

Rows **1, 2, 3, 4, 5, 6, 9** and the counter check all need a bearer token **from the tenant's own
Keycloak realm** (a v1 `spk`/`om1` token is rejected by the per-tenant decoder), `X-Tenant-ID` +
`facility_code`, and a real `stockUnit.id` with amount ≥ 2. None of that is in the repo, correctly.
They also **move real stock** — row 4 deliberately creates a second unit load, which *is* the assertion.

Runner: **`sbdocs/9-System/scripts/curl-matrix-SBDEV-3003-slice2.sh`**. It aborts on row 0 if the fix
is not live, runs the non-mutating rows first, and prints the exact DB query and expected delta after
each mutating row — a 200 proves the request was accepted, never that exactly one UL was created.

**Row 4 remains the row that justifies the whole design** and it is still unrun: it proves a
*deliberate* repeat move under a fresh nonce still goes through. If it ever replays, auto-derive has
leaked in and the fix is silently dropping real moves — worse than the bug.

---

## 6e. §5 curl matrix — RUN AND COMPLETE on DEV (2026-08-21)

Run against `https://wms-api.dev.sbo.li` (v2, Java 21) on the merged `develop` build, tenant
`wineco` / facility `wsl` — the only active tenant on DEV. Token: `panderson` in the `wineco` realm
on `kc2.dev.sbo.li`, client `om1-api`, carrying `wms_user` + `wms_admin` + `sb_admin`.

**API and DB confirmed to be the same environment before trusting anything** (the SBDEV-2781 trap):
the landlord's `tenant_db_configuration.db_url` for `wineco/wsl` is `dev.sbo.li:25060/dev_wh01_om1`
and the `wms2-wineco-dev` MCP points at `:25060/dev_wh01_om1`. Same DB, same port.

Fixture: `stockunit.id = 978427038` (VUSTK, 9991 on hand, unlocked, client 1050800) →
destination `UL302997` (empty, StagingLane06, same client, accepted by the API's own
`isUnitLoadIdValid` probe). `amountToTransfer = 1`, so every transfer is PARTIAL and the source
survives under the same PK — which is what makes row 4's repeat body byte-identical.

| Row | Assertion | Result |
|---|---|---|
| 0 | fix is deployed | **PASS** — 401 with no `www-authenticate` |
| 8 | no `Authorization` → clean 401, not 500 | **PASS** |
| F2 | valid realm token, **zero** WMS authorities → 403, not 500 | **PASS** — this is the row that would have caught review finding F2 |
| — | valid token, **no tenant headers** | **401 at JWT decode** — see the correction below |
| 7 | unrelated `/v3` POSTs unaffected | **PASS** — 7 other paths out of filter scope, incl. `transferStockToUnitLoad`, `bulkTransferStock`, `stockUnit/user/createUser`, `sysprop/save`, `user/save`, `userRole/delete`, `adminAction/run` |
| — | GET on the enrolled path | **PASS** — out of scope |
| 6 | no `Idempotency-Key` → proceeds UNDEDUPED, no auto-derived key | **PASS** — move executed, **zero** new `rest_idempotency` rows, and the 64-hex-key count stayed at its pre-run value of 36 (all `/rest/**`) |
| 1 | nonce N1 → 200, move happens | **PASS** — 1 claim row |
| 3 | nonce N1 again, sequential → replayed 2xx, **no second move** | **PASS** |
| 2 | nonce N2 twice concurrently | **PASS** — one `200`, one `409 {"error":"idempotency-in-flight"}`, **one** move |
| 5 | nonce N2, different body | **PASS** — `409 {"error":"idempotency-key-conflict"}`, a genuinely different string from row 2's, which is what the client discriminates on |
| **4** | **nonce N3, byte-identical body → must EXECUTE** | **PASS — 200 and the move happened.** The row that justifies the whole design: a replay here would have meant the fix silently DROPS deliberate repeat moves, worse than the reported bug |
| 9 | failing move under N4 → not cached as success | **PASS** — `200 {"errors":[{"message":"Container NO-SUCH-CONTAINER-XYZ was not found…"}]}` and **no claim row for N4**, so G-e dropped it |
| G-d | counter fires on dedupe outcomes only | **PASS** — `wms_idempotency_duplicate_transfer_total{outcome="in_flight",path="/v3/stockUnit/transferStock"} 1.0` and `{outcome="replayed",…} 1.0`. No `CLAIMED` series, so the metric is not inverted, and the `path` tag is the enrolled path only — review finding **F1's cardinality bound confirmed in production** |

### The ledger reconciles exactly — which is the real proof

Source `9991 → 9987` = **4 units moved**. Destination `UL302997` = **4.0**. Attributed:

| | moves |
|---|---|
| row 6 (no nonce, fail open) | 1 |
| row 1 (N1) | 1 |
| row 3 (N1 replay) | **0** |
| row 2 (N2, two concurrent) | **1** |
| row 5 (N2, different body) | **0** |
| **row 4 (N3, identical body)** | **1** |
| row 9 (failing) | **0** |
| **total** | **4** ✓ |

Claim rows after the run: exactly three — `N1=200`, `N2=200`, `N3=200`. **N4 absent** (G-e), and row 6
wrote none (G-b fail-open).

### Correction to §7's residual

§7 and §6c recorded "valid token + missing tenant headers → landlord routing → 500" as an open
residual. **Measured: it returns 401, not 500.** With no tenant header `MultiTenantJwtDecoder` falls
back to the default-issuer decoder, which rejects a *tenant-realm* token outright — so it fails at
JWT decode, before any routing or DB access. The `42P01` → 500 path is therefore not reachable for a
tenant-realm token at all; it would require a token issued by the default `rest.security.issuer-uri`,
a much narrower class than the residual implied.

### Observation for the next reader — the plan's "N new unit loads" wording

Rows 1–4 assert "one new unit load". On the `isTransferExistingContainer: true` path that is **wrong
as written**: stock is added INTO the existing destination container, so `unitload` row count does not
change at all (measured: 754,788 before and after). The correct observable is the destination's stock
amount plus the source decrement, which is what was used above. The unit-load count is the right
observable only on the path that mints a container — which is where the reported phantom-UL symptom
came from.

**Still owed after this:** only the per-environment CORS preflight check and handheld QA. Both need a
browser / device, not curl.

---

## 7. Residuals and review status

**Residuals of fail-open (i) — state these, don't discover them later:**

- **`wms2-web-ui` is a second, uncovered caller** of this endpoint
  (`store/handlingUnits/stockUnits.js:159` via `popups/transferStock.vue:113`) and sends no nonce, so it
  stays on client-side guards alone. It is not badly exposed — `execute()` sets `loading = true` before
  the `await` and the button is `:loading`-bound, which Vuetify disables — and its trigger is a mouse
  click, not a scanner CR. Extending the nonce there later is optional; if you do, note that the web UI
  exposes `printLabel` as an operator switch (`popups/transferStock.vue:43,104`), so a replay would
  silently skip a label the operator asked for. Mobile hard-codes `printLabel: false`, so this cannot
  bite today.
- **Older mobile builds in the field** send no nonce either. Slice 2 defends the patched build; it is not
  a guarantee for the endpoint.
- **CORS:** `rest.security.cors.allowed-headers=*` (`application.properties:99`) lets the
  `Idempotency-Key` preflight through today, but the property is env-overridable and SBDEV-2632 exists
  because an env overrode the sibling `exposed-headers`. If any env pins an explicit list the preflight
  fails, the request never leaves the browser, and Move Stock breaks **entirely** as a generic network
  toast. **Pre-deploy check per environment**; note that neither curl nor the DevTools Network panel
  reliably verifies CORS header handling in this repo.
- **`nonce ⇒ exactly-once` is not true.** `RestIdempotencyService:117-129` deletes and re-claims any
  `102` row older than **60 s**, so a first transfer that legitimately runs longer than that (the
  existing-container pallet branch does several writes plus `transferUnitLoadToCarrier`) will let a
  re-tap with the same nonce execute a second move. Same if `persistResponse` fails — it is caught and
  merely warned (`IdempotencyFilter:247-249`), leaving the row at `102`.

**Review status.** Lane 1 (architect) **complete** — 3 High, 4 Medium, 4 Low; central design confirmed;
all three Highs independently re-verified before being folded in above. Full record:
[[reviews/SBDEV-3003-slice2-review-architect]]. Lane 2 (adversarial row discrimination) **complete** —
[[reviews/SBDEV-3003-slice2-row-discrimination]]; see §6. **Both T2 lanes are now done and the plan is
revised against both. It is ready for implementation once Nam accepts the T2-vs-T3 call in the note
under the title.**

Escalate to **T3** if the design grows a table or Flyway migration after all (tenant-chain failures are
silent), or if it outgrows *one filter + one key policy + one store*. The auth-adjacent trigger has
already fired and is answered by G-f — see the note under the title.
