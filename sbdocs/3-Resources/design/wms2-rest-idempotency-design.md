---
type: design
status: active
system: wms2
last_verified: 2026-08-21
verified_by: Claude (analysis — IdempotencyFilter.java + RestIdempotencyService.java; re-verified against SBDEV-3003 Slice 2)
tags: [wms2, idempotency, rest, oms-integration, deduplication, sbdev-2222, sbdev-3003]
related:
  - ../architecture/wms2-oms-integration-map.md
  - ../architecture/wms2-end-to-end-request-journey.md
  - ../architecture/wms2-scheduled-jobs-catalog.md
---

## TL;DR
- `IdempotencyFilter` guards all `POST`/`PUT` `/rest/**` endpoints against OMS duplicate delivery (OMS retries on network timeout).
- **SBDEV-3003 Slice 2** additionally enrols a **one-path allow-list under `/v3`** — `POST /v3/stockUnit/transferStock` (mobile Move Stock) — under **client-nonce-only** rules. The allow-list is exact-match and never a `/v3` prefix: `AdminController` is mapped at `/v3` with 43 subclasses, so a prefix would silently enrol ~215 non-GET endpoints (user and sysprop writes included) that no mapping grep reveals.
- Key is **auto-derived** from `SHA-256(method + "|" + path + "|" + rawBodyBytes)` — no header coordination required. An explicit `Idempotency-Key` header overrides the auto-key (back-compat for legacy OMS callers). **Auto-derive is DISABLED on the `/v3` allow-list**: a deliberate repeat Move Stock sends a byte-identical body, so a content-derived key would silently replay — and therefore drop — the real second move for the 7-day retention window. A caller sending no nonce there falls through **undeduped** (fail open), keeping older handheld builds working.
- A true duplicate (same method + path + body) gets its **cached 2xx response replayed** — the handler never runs a second time.
- Controlled entirely by `app.idempotency.enforce=true/false`. When `false`, the filter is **completely bypassed** — every request reaches the handler with no dedup.
- Observable via `rest_idempotency` table (tenant DB) + `RestIdempotencyCleanupJob` (7-day retention).

---

# WMS2 REST Inbound Idempotency Design

## Key Files

| File | Role |
|---|---|
| `landlord/config/IdempotencyFilter.java` | Servlet filter — key derivation, claim/replay/conflict routing, response capture |
| `service/RestIdempotencyService.java` | DB operations — `tryClaim`, `persistResponse`, `getCachedResponse` |
| `schedulejob/RestIdempotencyCleanupJob.java` | Nightly cleanup — deletes `SENT` rows older than 7 days |
| `db/v1-to-v2-onboarding/schema/V2.1.10__add_rest_idempotency.sql` | `rest_idempotency` table DDL (tenant DB) |

---

## `app.idempotency.enforce=false` — Filter Completely Bypassed

`IdempotencyFilter` extends `OncePerRequestFilter`. `shouldNotFilter()` is checked before the filter body runs:

```java
protected boolean shouldNotFilter(HttpServletRequest request) {
    if (!enforce) {
        return true;   // Spring skips doFilterInternal() entirely
    }
    ...
}
```

When `enforce=false`:

| What stops working | Effect |
|---|---|
| Duplicate detection | OMS retries hit the handler a second time — same state change executes twice |
| Cached response replay | No 2xx response stored or replayed |
| Hash-conflict rejection | No 409 for key+body hash mismatch |
| `rest_idempotency` table | Never written to (existing rows remain untouched) |
| `/rest/sku/**` cache eviction on replay | Skipped (irrelevant when replay itself is off) |

**When safe to use:** dev/local testing without real OMS traffic. Never in staging or production with live OMS retries — risks duplicate order releases, duplicate receiving posts, etc.

---

## `app.idempotency.enforce=true` — Full Dedup Active

### Requests excluded even with enforce=true

The filter skips itself (via `shouldNotFilter()`) for:
- All `GET` requests — including on the `/v3` allow-list
- Any URI not starting with `/rest/` **and not on the `/v3` allow-list** (SBDEV-3003 Slice 2: `V3_ALLOW_LIST`, currently the single entry `/v3/stockUnit/transferStock`)
- `/rest/stockcount/**`
- `/rest/transactionreport/**`

### `/v3` allow-list — three rules that do NOT apply to `/rest/**` (SBDEV-3003 Slice 2)

| Rule | Why `/rest/**` differs |
|---|---|
| **Auth is required in code**, independent of `app.idempotency.require-auth` | `/rest/**` is `permitAll` and OMS may not send a JWT, so `require-auth=false` is benign there. `/v3/**` is `hasAnyAuthority("wms_user")`, but this filter runs *before* `AuthorizationFilter`, so without the in-code gate an anonymous POST reaches `tryClaim`; with no tenant header that write routes to the **landlord** DB, where `rest_idempotency` does not exist → `42P01` → **500** instead of a clean 401 |
| **Bridge mode is suppressed per request** (`tryClaim(…, allowBridgeMode=false)`) | Bridge mode matches on `(requestHash, method, path)` and *ignores the key*, so a fresh unique nonce would still REPLAY off an unrelated row — re-introducing the silent drop the nonce exists to prevent. Suppression is code-level, not a reliance on `bridge-mode=false` |
| **A 2xx carrying an `errors` key is not cached** | `StockUnitController` answers business failures with HTTP **200** plus an `errors` body, and `persistResponse` drops only non-2xx. Caching that would replay the failure forever after the operator's blocker cleared, and a corrected input would then 409 |

The client half (nonce minting, and discriminating `idempotency-in-flight` from `idempotency-key-conflict`) lives in `wms2-mobile-ui` `store/moveStock.js`.

### Request processing pipeline

```
1. Auth check
   └─ unauthenticated caller? → 401 (defence-in-depth before any DB roundtrip)

2. Body-size cap (fast path)
   └─ Content-Length > maxBodyBytes (default 5 MB)?
      → chain.doFilter() — no dedup (DoS guard)

3. Buffer body (ContentCachingRequestWrapper + drain)

4. Body-size cap (authoritative post-drain check)
   └─ actual buffered size > maxBodyBytes?
      → chain.doFilter() — no dedup (handles chunked transfer-encoding)

5. Key derivation
   ├─ Idempotency-Key header present?
   │   ├─ fails [A-Za-z0-9_-]{1,64} regex? → 400 {"error":"invalid-idempotency-key"}
   │   └─ valid → use header value as key
   └─ no header → key = SHA-256(METHOD + "|" + path + "|" + rawBodyBytes)

6. bodyHash = SHA-256(rawBodyBytes)   [separate from composite key]

7. tryClaim(key, method, path, bodyHash)  → one of four outcomes below
```

---

### The four outcomes of `tryClaim()`

#### CLAIMED — first time this key is seen

```
INSERT ... ON CONFLICT DO NOTHING → row created with status=IN_FLIGHT
→ handler runs
→ persistResponse():
    2xx response  → row updated to SENT, body cached
    4xx/5xx/throw → claim row deleted (OMS can safely retry)
→ real response returned to OMS
```

#### REPLAYED — duplicate with matching body (the happy path)

```
Existing row found: method ✓  path ✓  bodyHash ✓  status=SENT
→ handler never runs
→ cached 2xx response written directly to HttpServletResponse
→ /rest/sku/** replay: itemdata Caffeine cache cleared explicitly
  (mirrors the handler's @CacheEvict that did not fire — P2-1 fix)
→ OMS receives identical response to the original request
```

#### IN_FLIGHT — duplicate arrives while first is still processing

```
Existing row found: status=IN_FLIGHT, age < stale TTL
→ HTTP 409  {"error":"idempotency-in-flight","key":"<key>"}
OMS should back off and retry after the first request completes.
```

**Stale IN_FLIGHT recovery** (crashed replica):
```
Existing row found: status=IN_FLIGHT, age ≥ stale TTL (~60 s)
→ row re-claimed (reset to IN_FLIGHT with fresh timestamp)
→ ClaimResult.CLAIMED — handler runs again
```
Prevents the key from being permanently stuck when a replica crashed mid-request.

#### CONFLICT — same key, different body (OMS bug)

```
Existing row found: key matches, bodyHash ✗
→ HTTP 409  {"error":"idempotency-key-conflict","key":"<key>"}
```

Only possible when OMS sends an explicit `Idempotency-Key` header and reuses the same key value with a different payload. **Mathematically impossible for auto-generated SHA-256 keys** — the composite hash embeds the body.

---

### Full state machine (summary)

```
First request ──────────────────────────────► CLAIMED → handler runs
                                                         └─ 2xx → SENT (cached)
                                                         └─ 4xx/5xx/throw → row deleted

Retry (same method+path+body) ───────────────► REPLAYED → cached response, no handler

Retry (in-flight, fresh) ────────────────────► IN_FLIGHT → 409

Retry (in-flight, stale — replica crashed) ──► CLAIMED again → handler re-runs

Same key, different body ────────────────────► CONFLICT → 409
```

---

## Bridge Mode (`app.idempotency.bridge-mode=true`)

During the UUID→SHA-256 key transition window (260520 migration), bridge mode allows the filter to look up pre-existing UUID-keyed rows by the new SHA-256 key. When a newly-CLAIMED SHA-256 row is found to have a matching UUID-keyed predecessor, the response is replayed and `REPLAYED` is returned. Prevents duplicate handler execution during the transition. Set `false` once all OMS callers have stopped sending the old UUID header.

---

## Operational Notes

| Property | Default | Effect |
|---|---|---|
| `app.idempotency.enforce` | `true` | `false` = filter completely bypassed |
| `app.idempotency.max-body-bytes` | 5 MB | Requests above this size skip dedup |
| `app.idempotency.bridge-mode` | `false` | Enable during UUID→SHA-256 transition |

- **Dedup rows** are stored in the **tenant** DB (`rest_idempotency` table), not the landlord.
- **Cleanup**: `RestIdempotencyCleanupJob` deletes `SENT` rows older than 7 days (advisory lock `100007L`).
- **MDC**: `idempotencyKey` is injected into the logging MDC for the duration of each request — all downstream log statements carry it for correlation.
- **Observability**: no dedicated Micrometer counter on the filter itself; use `rest_idempotency` row counts + `RestIdempotencyCleanupJob` metrics for volume trends.

---

## Related Docs
- [[wms2-oms-integration-map]] — outbound WMS→OMS path (outbox dispatcher, OMS notification service)
- [[wms2-scheduled-jobs-catalog]] — `RestIdempotencyCleanupJob` entry (advisory lock `100007L`, 7-day retention)
- [[wms2-end-to-end-request-journey]] — where `IdempotencyFilter` sits in the full request pipeline
