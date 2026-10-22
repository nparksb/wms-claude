---
name: sbdev-3003-slice2-transfer-stock-idempotency
description: SBDEV-3003 Slice 2 (v2) — /v3/stockUnit/transferStock enrolled in IdempotencyFilter under a client nonce; implemented 2026-08-21; LANDMINE auto-derive would silently drop a deliberate repeat move
metadata: 
  node_type: memory
  type: project
  originSessionId: 74e9ade3-54f9-40c9-b7fd-5f0d8ec80cce
  modified: 2026-08-21T12:52:48.155Z
---

Move Stock double-submit created phantom unit loads. Slice 2 enrols
`POST /v3/stockUnit/transferStock` in the existing SBDEV-2222 `IdempotencyFilter` subsystem — **no
new table, no Flyway migration**, only scope + key policy + three safety rules.

Implemented 2026-08-21: `wms2-api` `a8e2997` on `bugfix/SBDEV-3003-slice2-transfer-stock-idempotency`,
`wms2-mobile-ui` `ef54f57` on `bugfix/SBDEV-3003-slice2-move-stock-nonce`. Both off fresh
`origin/develop`, NOT stacked on Slice 1 (whose v2 PRs api #175 / mobile-ui #39 were still open —
the parent plan's "MERGED" refers to the **v1** repos).

**THE LANDMINE — auto-derive is the tempting design and it is catastrophic.** The filter derives a
key from `SHA-256(method|path|body)` when no header is present, which would have fixed the reported
bug with *zero UI change*. But a **deliberate** repeat move (same source, destination, amount,
comment) sends a byte-identical body, so it gets the same key and is silently `REPLAYED` — the
operator sees "Stock moved" and nothing moves, for the **7-day** retention window. A silently
dropped real move is worse than the phantom ULs. Hence: nonce-only, auto-derive gated off, and the
no-nonce case **fails open** (older handheld builds keep working).

Three more rules that apply to `/v3` and NOT to `/rest/**`:
- **Auth in code.** The filter runs after `BearerTokenAuthenticationFilter` but `AuthorizationFilter`
  runs LAST, so it executes before the `wms_user` check. With the shipped `require-auth=false` an
  anonymous POST reaches `tryClaim`; with no tenant header that routes to the **landlord** DB where
  `rest_idempotency` does not exist → `42P01` → **500**, not 401. `/rest/**` is `permitAll`, which is
  why the property was benign there.
- **Bridge mode suppressed per request.** It matches `(requestHash, method, path)` and *ignores the
  key*, so a fresh unique nonce still replays off an unrelated row. A property defaulting to false
  is a config claim, not a code guarantee.
- **A 2xx with an `errors` body must not be cached.** `StockUnitController` answers every business
  failure with HTTP 200, and `persistResponse` drops only non-2xx — so a locked destination would be
  cached as the success and replay forever after the blocker cleared.

Scope must be an **exact-match allow-list**, never `startsWith("/v3/")`: `AdminController` is mapped
at `/v3` with 43 subclasses × 5 non-GET methods re-registered per subclass prefix ⇒ ~215 non-GET
endpoints invisible to a mapping grep, `/v3/user/**` and `/v3/sysprop/**` included. And
`transferStockToUnitLoad` is a real sibling symbol that is a substring-superset of the path.

Still owed: the 9-row **manual curl matrix on DEV** (nothing was executed against a live chain or
DB — rows 4/6/7/8/9 catch the catastrophic designs), the per-env **CORS** check for the
`Idempotency-Key` preflight, and handheld QA. Also: `wms2-web-ui` is a second uncovered caller of
this endpoint and sends no nonce.

Related: [[sbdev-3003-version-defeated-by-stale-operand]],
[[mutation-harness-traps]],
[[sbdev-2726-shared-vuex-blob-facility-code]]
