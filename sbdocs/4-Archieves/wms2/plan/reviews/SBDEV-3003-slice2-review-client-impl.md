---
title: "SBDEV-3003 Slice 2 — independent review of the mobile client nonce (ef54f57)"
date: 2026-08-21
type: review
status: complete
lane: independent client-implementation review
target: "wms2-mobile-ui ef54f57 on bugfix/SBDEV-3003-slice2-move-stock-nonce (off 7f83d55)"
plan: "[[SBDEV-3003-slice2-transfer-stock-idempotency]]"
related:
  - "[[SBDEV-3003-slice2-transfer-stock-idempotency]]"
---

# SBDEV-3003 Slice 2 — independent review of the mobile client nonce

Reviewed commit `ef54f57` in `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-mobile-ui/SBDEV-3003-slice2`.
Files: `store/moveStock.js` (modified), `test/store/moveStockNonce.spec.js` (new, 226 lines).
Server counterpart read at `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3003-slice2`.

Baseline reproduced: **169 passed, 11 suites, 0 failures**, matching the commit message. Working tree
restored clean after every probe and mutant (`git status --porcelain` empty).

---

## Verdict

**The central design is correct and I verified each of its three load-bearing mechanisms by
measurement rather than by reading.** The `Idempotency-Key` header genuinely reaches the wire through
the real axios the app resolves; it genuinely does not leak onto the shared axios defaults; and
`error.response.data.error` genuinely carries the two discriminator strings the server writes. Module
scope is the right home for the nonce in this app, and every UI intent boundary releases it — I walked
all four exhaustively and found **no path that leaks a nonce into a different operator intent**, which
was the primary hazard the brief asked me to hunt.

**One High stands, and it is a design gap rather than a coding error:** the in-flight 409 is suppressed
into *total silence*, and the server re-claims a stale in-flight row after **60 seconds**. Those two
facts are each recorded in the plan, in different sections, and never joined. Together they mean a
slow or hung transfer gives the operator no feedback on any re-tap, and the first re-tap past the 60s
mark performs a **second real move**. The app's own generic error copy says "Please retry."

**The test suite is materially weaker than the commit message implies.** The commit lists 7 client
mutants; I ran 8 more and **four survived**, including the one protecting the single most load-bearing
invariant in the diff (that the in-flight branch must *not* release the nonce). Deleting the entire
`idempotency-key-conflict` branch leaves the full 169-test suite green. Deleting the success branch's
two workflow commits also leaves it green — in a commit whose message says that branch was
restructured. And plan §5.7's explicit "stable across … **a component re-mount**" is not tested at
all; the code comment asserting it is also inaccurate as written.

Nothing here is a blocker for the *approach*. H1 wants a small client change; M1–M4 want assertions.

**Count: 1 High, 5 Medium, 4 Low.**

---

## Findings

| # | Sev | Site | What breaks | Suggested fix |
|---|-----|------|-------------|---------------|
| **H1** | **High** | `store/moveStock.js:264-269` + `RestIdempotencyService.java:62,160` | Silent in-flight suppression × the server's 60s stale-claim reclaim = **a duplicated stock move with no operator feedback at any point**. See detail below. | Replace silence with non-error feedback (`$toast.info`), and add a module-scope in-flight latch so the second dispatch never reaches the network. |
| **M1** | Medium | `test/store/moveStockNonce.spec.js` (absent assertion) | Nothing pins that the in-flight branch must **not** release the nonce. Mutant adding `transferNonce = null` at `:268` → **13/13 green**. That mutant duplicates a move on the very next re-tap, with no 60s wait needed. | Assert: 409-in-flight, then re-tap → `sentNonce(post,1) === sentNonce(post,0)`. |
| **M2** | Medium | `test/store/moveStockNonce.spec.js:196-204` | The whole `idempotency-key-conflict` branch is unpinned. Deleting `store/moveStock.js:270-277` outright → **169/169 green**. The test only asserts `toast.error` was called, and the generic fallback at `:281` also calls it. Plan §5.7 requires the conflict be "**surfaced**". | Assert the specific message string, and assert the nonce was released (third call gets a new nonce). |
| **M3** | Medium | `store/moveStock.js:67` (untested) | Mutant removing the nonce clear from `resetState` → **169/169 green**. `resetState` is the *only* boundary covering "operator abandons the screen after a transport failure, leaves the page, re-enters" (`pages/move-stock.vue:25`). Without it a retained nonce reaches the next intent, and a byte-identical deliberate repeat is REPLAYED — a silently dropped move for up to 7 days. `initialize`'s equivalent clear **is** pinned (its mutant reds 1 test). | Mirror the existing `initialize` test: transport-fail, `mutations.resetState(state)`, re-tap → fresh nonce. |
| **M4** | Medium | `store/moveStock.js:257-258` (untested) | Mutant deleting `context.commit('initialize')` **and** `context.commit('setProcess', '1_select')` from the success branch → **169/169 green**. A successful move would leave the operator on Scan Destination with stale stock loaded, and nothing in the repo notices. The commit message says this branch was restructured. | One assertion on the mocked `context.commit` calls for the success path. |
| **M5** | Medium | `store/moveStock.js:7` and plan §5.7 | §5.7 requires the nonce be "stable across a re-tap **and a component re-mount**". No spec in the diff mounts anything. The comment's claim is also inaccurate: it holds for the *child* (`components/moveStock/scanDestination.vue`) but **not** for `pages/move-stock.vue`, whose `created()` → `resetState` clears it (`pages/move-stock.vue:24-26`). | Add a `mount`/`destroy`/`mount` spec on `scanDestination.vue`; reword the comment to "survives a re-mount of the destination component". |
| **L1** | Low | `store/moveStock.js:274` | "Please start the move again." is advice the operator does not need — the nonce is released and a straight re-tap succeeds; store state is untouched. And when the conflict arose from an *offline* first attempt, "this move was already submitted with different details" is factually wrong: nothing was submitted. | "This move's details changed since you submitted. Scan the destination again." |
| **L2** | Low | `store/moveStock.js:31` | `Math.random().toString(36).slice(2, 12)` yields fewer than 10 chars whenever the float's base-36 expansion is short (at `Math.random() === 0`, an empty string — leaving only `n` + the millisecond). Charset and length are still valid, and a collision is self-healing (different bodies → CONFLICT → toast + release → retry works), so impact is genuinely low. | Two `Math.random()` draws, or pad to a fixed width. |
| **L3** | Low | `store/moveStock.js:27-29` | `Array.from` (mapFn) and `String.prototype.padStart` are ES2015/ES2017. Safe today — no `browserslist` in `package.json` and no `.browserslistrc`, so Nuxt 2's default babel preset (`useBuiltIns: 'usage'`, `core-js@^3.19.3` is a dependency) polyfills both. The hazard is the *failure mode* if targets ever narrow: `newTransferNonce()` is called **inside** the `try`, so a `TypeError` is swallowed at `:260` and surfaces as the generic network toast — the move silently never fires, which is exactly what the fallback chain exists to prevent. | Hoist the mint above the `try`, or wrap `newTransferNonce` in its own try/catch returning the base36 rung. |
| **L4** | Low | `application.properties:99` (env-overridable) | `Idempotency-Key` is a non-safelisted request header, so it **requires** preflight approval. `rest.security.cors.allowed-headers=*` admits it today — confirmed. If any environment pins an explicit list via `REST_SECURITY_CORS_ALLOWED_HEADERS`, the preflight fails, the request never leaves the browser, and Move Stock breaks **entirely** as a generic network toast. Already recorded in plan §7; flagged here only to confirm it is real and still outstanding. | Per-environment pre-deploy check (plan §6b "still owed" item 2). |

### H1 in detail

`store/moveStock.js:264-269` returns from the `idempotency-in-flight` branch with **no toast, no state
change, no screen advance** — the operator gets nothing at all.

Three facts compound:

1. **There is no client timeout.** `nuxt.config.js:64-68` sets only `baseURL`, and `plugins/axios.js`
   never sets `timeout`, so `@nuxtjs/axios` leaves it at 0. A slow first request (`D1`) does not fail
   fast — the screen simply sits there.
2. **So during any slow transfer the operator's total feedback is zero**, and re-scanning is the
   natural response on a handheld. Each re-scan returns in-flight and is silently swallowed. This part
   is *certain*, not conditional, and on its own matches the brief's "operator stuck with no feedback".
3. **`RestIdempotencyService.java:62`** — `STALE_CLAIM_TTL = Duration.ofSeconds(60)` — and **`:160`**:
   a `102` row older than 60s is deleted and re-claimed. So a re-tap more than 60 seconds after the
   claim **executes a second real move**, shows "Stock moved", and leaves two unit loads. That is the
   SBDEV-3003 symptom, reached through the fix.

Reaching it requires a transfer that runs >60s. That is not everyday, but it is documented as reachable
in this repo (the `REQUIRES_NEW`-in-a-lock-holding-transaction class hangs *indefinitely*, and the
existing-container branch does several writes plus `transferUnitLoadToCarrier`). Under an indefinite
hang each successive 60s window admits one more real move, and the operator has been given no reason
to stop tapping — the app's own generic copy at `:281` says "Please retry."

The plan records both halves — §3's "Suppress the error toast (benign)" and §7's fourth residual
("`nonce ⇒ exactly-once` is not true … older than 60 s") — but never joins them, and nothing in the
diff mitigates the join.

Suggested fix, in order of strength:

- **A client-side in-flight latch** (module scope, released on exactly the same terminal outcomes as
  the nonce). The second dispatch never reaches the network, so the 60s window is never entered. This
  is the real fix and it is a few lines beside the nonce it already parallels.
- **Plus** non-error feedback on the branch, so silence is not the operator's experience:
  `this.$toast.info('This move is still being processed — please wait, do not re-scan')`. Suppressing
  the *error* toast (the plan's actual requirement) does not require suppressing *all* feedback.

---

## Mutation results

All run from the worktree with the real Jest config; source restored from a pristine copy after each.

| # | Mutant | Result |
|---|--------|--------|
| M1 | in-flight branch **also** clears the nonce | **SURVIVED** — 13/13 green (finding M1) |
| M2 | key-conflict branch **keeps** the nonce | **SURVIVED** — 13/13 green (finding M2) |
| M3 | `initialize` mutation keeps the nonce | killed — 1 red |
| M4 | `resetState` mutation keeps the nonce | **SURVIVED** — 169/169 green (finding M3) |
| M5b | success branch drops `initialize` + `setProcess('1_select')` | **SURVIVED** — 169/169 green (finding M4) |
| M6 | both dedupe marker strings wrong | killed — but only **1** red, which is what exposed M2 |
| M7 | `idempotency-key-conflict` branch **deleted entirely** | **SURVIVED** — 169/169 green (finding M2) |
| M8 | success branch's *explicit* nonce clear removed (`initialize`'s kept) | killed — 1 red. The commit's stated "one implementation change the tests forced" is genuinely pinned. |

---

## Checked and ruled out

Listed so a later reader can tell coverage from silence.

1. **The header reaches the wire.** Runtime probe against the real axios the app resolves — **0.21.4**,
   nested at `node_modules/@nuxtjs/axios/node_modules/axios`, *not* the hoisted root `axios@1.16.1`.
   The stub adapter saw `Idempotency-Key: n1abcDEF-_9` alongside `Authorization` / `X-Tenant-ID` /
   `facility_code`, with the `common` sub-object correctly stripped. Mechanism:
   `@nuxtjs/axios/lib/plugin.js:63-65` replaces `config.headers` with
   `{...defaults.headers.common, ...config.headers}` — which *preserves* the `common` key, so
   `plugins/axios.js:125`'s `config.headers.common` branch still works — then
   `axios/lib/core/dispatchRequest.js:37-48` flattens with the top-level keys spread **last**, so a
   per-request top-level header wins. Header case is preserved (0.x does not normalize), and the
   servlet `getHeader` is case-insensitive anyway.
   *Worth recording:* had the app resolved the hoisted `axios@1.16.1`, `plugins/axios.js:145` would
   throw on **every** request (1.x flattens headers *before* interceptors, so `config.headers.common`
   is `undefined`). Not a defect in this diff, but the whole plumbing rests on that nested pin.
2. **No leak onto the shared axios defaults (SBDEV-2726 class).** Probe: `defaults.headers.common`
   stayed `{"Accept":…}`, and a *second* `$post` with no config did **not** carry the header.
   `mergeConfig`'s `deepMerge` makes a fresh copy of `headers.common`, so even the plugin's writes
   there cannot reach the defaults.
3. **`error.response.data.error` really is the parsed field for both 409s.** `IdempotencyFilter:270-275`
   (CONFLICT) and `:299-304` (IN_FLIGHT) both `setContentType("application/json")` and write
   `{"error":"…"}`. Probe through `$post` confirmed `typeof error.response.data === 'object'` and
   `.error === 'idempotency-in-flight'`. The `400 invalid-idempotency-key` body at `:229` has the same
   shape, so a charset regression would land in the generic branch rather than crashing.
4. **No interceptor transforms or swallows the error.** `plugins/axios.js:167-174` rejects unchanged;
   `@nuxtjs/axios`'s own `onError` (`plugin.js:161-177`) only touches the loading bar and returns
   `undefined`, and `onResponseError` is registered as `fn(error) || Promise.reject(error)`, so the
   original error propagates.
5. **No retry, and no retry storm.** `plugins/axios.js:36-39` returns `false` for any status that is
   not 401/403 **and** for `!error.response`, so neither 409 nor a transport failure is retried —
   confirming plan §3's claim. A 401/403 refresh-retry *does* re-send the same
   `Idempotency-Key` (it lives on `error.config.headers`), which is correct: a token-refresh retry must
   dedupe. And `IdempotencyFilter` runs after `BearerTokenAuthenticationFilter`, so an unauthenticated
   attempt is refused at `:180-188` before any claim row is written.
6. **Nuxt SSR / multiple store instances.** `nuxt.config.js:5` — `ssr: false`. Client-only SPA: one
   store per page load, one webpack module instance for `store/moveStock.js`. Module-level mutable
   state is safe here and the plan's stated lifetime ("dies with the page load") holds.
7. **The nonce is not persisted.** `plugins/persistedState.client.js` persists Vuex *state* under
   `vuex-mobile`; `initialState()` (`store/moveStock.js:44-53`) has 8 keys, none nonce-related. The
   `toEqual(state())` drift guard in `test/store/resetState.spec.js` still passes, so the added
   module-scope write did not disturb SBDEV-2930's reflection test.
8. **No `keep-alive` anywhere.** `layouts/no-tenant.vue:9` is a bare `<nuxt />`; no layout or page uses
   `keep-alive`. So `pages/move-stock.vue:25`'s `created()` → `resetState` really does run on every
   page entry. (If `keep-alive` were ever added, `created()` would stop firing and the nonce *would*
   leak across intents — the same latent trap as SBDEV-2930's state reset. Worth a comment.)
9. **Every UI intent boundary releases the nonce — enumerated exhaustively.** The only exits from
   `3_destination` are `goBack()` (`components/moveStock/scanDestination.vue:140-141` → `initialize`),
   a successful submit (explicit release + `initialize`), `pages/move-stock.vue:25` on page entry
   (`resetState`), and `components/moveStock/inputAmount.vue:93-94` (`initialize`). **There is no path
   that reaches `1_select`, or starts a new source scan, without passing through `initialize` or
   `resetState`.** So a nonce retained by the transport-error branch cannot reach a *different*
   operator intent through the UI. This was the brief's primary hunt and the code is correct — it is
   only *untested* at the `resetState` boundary (finding M3).
10. **The missing `await` at the call site does not break nonce correctness.**
    `components/moveStock/scanDestination.vue:224` dispatches without `await`, and the `submitting`
    latch is released at `:186` *before* the dispatch, so it does not cover the transfer at all.
    It does not matter: `currentTransferNonce()` is evaluated **synchronously** on entry to the action
    (it is an argument to `$post`, before the first `await`), so two overlapping dispatches always read
    the same non-null nonce. This holds identically in the Slice-1 world where the `await` is present.
    The one window — a second scanner CR arriving *after* `D1` resolved — cannot double-move either:
    `initialize` has already nulled `currentStockInfoDto`, so `submit()` throws at `:215`
    (`currentStock.stockUnit.id`) or `:200` before any request is built.
    *Pre-existing oddity, not caused by this diff:* if a second `submit()` got past `:159` while `D1`
    was still running and the probe `await` pushed it past `D1`'s completion, `:216` reads **live**
    `this.amount` — 0 after `initialize` — and would POST a 0-amount move under a fresh nonce.
11. **Charset and length of all three rungs**, against `IdempotencyFilter:86`
    `[A-Za-z0-9_\-]{1,64}` used with `.matches()` (fully anchored): `randomUUID` → 36 chars, hex plus
    `-`; `getRandomValues` → 32 lowercase hex; last resort → `n` + base36, ≤19 chars. All pass, so no
    silent `400 invalid-idempotency-key` (`:225-232`). The spec's own `KEY_REGEX` is correctly anchored
    and equivalent to the server's.
12. **`REPLAYED` handling on the client.** A replayed cached 2xx flows into the ordinary success branch
    (one extra "Stock moved" toast, no second move). The cached-row-missing case returns **204**, where
    `$post` yields `''` and `''.errors` is `undefined` — the `else` branch, no throw.
13. **The server actually enforces**, so the client header is not inert:
    `application.properties:125` `app.idempotency.enforce=true` and
    `SecurityConfiguration:61` `@Value("${app.idempotency.enforce:true}")`. The
    `app.idempotency.require-auth=false` in properties is overridden **in code** for this path by G-f
    (`IdempotencyFilter:180`).
14. **`Uint8Array`** — ES2015, present in any WebView that runs Nuxt 2 / Vue 2 at all. The real
    question was `padStart` / `Array.from`, covered in L3.
15. **Full suite parity.** 169/169 green on `ef54f57`; no pre-existing failures on this branch to net
    out (unlike `wms2-web-ui`). Tree restored clean after every mutant.

## Not checkable from here

- **Plan §5's 9-row curl matrix on DEV** (plan §6b "still owed" item 1). Nothing in this review booted
  a filter chain or touched a database. Row **4** — a deliberate repeat under a *new* nonce must create
  a second UL — is the one that would catch a nonce failing to rotate, and no unit test substitutes
  for it. Rows 6, 7, 8, 9 likewise.
- **Real-device behaviour of the `randomUUID`-absent path** on a plain-HTTP Android WebView.
- **CORS preflight per environment** (L4). Per the repo's own recorded experience, neither curl nor the
  DevTools Network panel reliably verifies CORS header handling here.
