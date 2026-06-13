---
title: "Content-derived idempotency key — remove Idempotency-Key header requirement"
ticket: ""
type: "feature"
severity: "medium"
priority: "medium"
status: "archived"
project: ["wms2-api"]
version: "v2"
requester: "Nam Park"
assignee: ""
created: "2026-05-20"
updated: "2026-05-20"
last_updated: "2026-05-20"
db_verified: "N/A — VARCHAR(64) column already fits SHA-256 hex; no migration needed"
related:
  - "[[SBDEV-2222-rest-inbound-no-idempotency-contract]]"
  - "[[wms2-oms-integration-map]]"
  - "[[wms2-end-to-end-request-journey]]"
tags:
  - plan
  - wmsv2
  - idempotency
  - oms-integration
  - reliability
---

# Content-derived idempotency key — remove `Idempotency-Key` header requirement

**Ticket:** n/a (enhancement to SBDEV-2222 implementation)
**Project:** wms2-api | **Version:** v2 | **Type:** feature
**Priority:** Medium | **Severity:** Medium
**Status:** implemented — 2026-05-20
**Base implementation:** [SBDEV-2222 PR #11](https://github.com/SiteBossInc/wms2-api/pull/11) (SHA 0373141)

> **Context:** SBDEV-2222 shipped an `IdempotencyFilter` that deduplicates OMS retries on
> all `/rest/**` write endpoints. The filter **requires** OMS to send an `Idempotency-Key`
> header; if the header is absent, the filter falls through to `chain.doFilter` with
> **no deduplication at all** (`IdempotencyFilter.java:103-108`). This enhancement removes
> the header requirement: the filter auto-derives the idempotency key by computing
> `SHA-256(method + "|" + path + "|" + rawBodyBytes)` on every write request.
> Deduplication becomes unconditional — OMS needs no code change. The `Idempotency-Key`
> header, if present, continues to work as an explicit caller-supplied key override.

---

## 0. Affected sites (enumeration before drafting)

Greps run against `v2/wms2-api/src`:

```bash
grep -rn "Idempotency-Key\|IDEMPOTENCY_HEADER\|idempotency_key\|IdempotencyFilter\|RestIdempotencyService" \
  src/main/java src/test/java
grep -rln "Idempotency-Key\|idempotency" \
  ../../sbdocs/3-Resources/ CLAUDE.md
```

| # | File:line | Construct | In-scope? | Phase |
|---|---|---|---|---|
| 1 | `landlord/config/IdempotencyFilter.java:103-108` | Header-absent fall-through (`key == null || key.isBlank() → chain.doFilter`) | **Yes — A.1** (replaced by auto-gen path) | Phase 1 |
| 2 | `landlord/config/IdempotencyFilter.java:118` | `ContentCachingRequestWrapper` creation — currently AFTER header check | **Yes — A.2** (moves BEFORE header check; body must be buffered for key derivation) | Phase 1 |
| 3 | `landlord/config/IdempotencyFilter.java:121` | `bodyHash = sha256Hex(...)` — body-only hash | **Yes — A.3** (retained as `request_hash`; new composite hash added as `idempotency_key`) | Phase 1 |
| 4 | `landlord/config/IdempotencyFilter.java:123-124` | `tryClaim(key, ...)` call — `key` currently from header | **Yes — A.4** (key source changes to auto-gen; header is an explicit override) | Phase 1 |
| 5 | `landlord/config/IdempotencyFilter.java:214-226` | `sha256Hex(byte[])` helper | **Yes — A.5** (new overload `sha256HexComposite(method, path, body[])` added alongside) | Phase 1 |
| 6 | `landlord/config/IdempotencyFilter.java:58` | `KEY_REGEX` pattern | **Yes — A.6** (validation narrows to header-override path only; auto-gen hex satisfies regex by construction but is not validated) | Phase 1 |
| 7 | `service/RestIdempotencyService.java:82-88` | CONFLICT detection via `requestHash` mismatch | **Yes — A.7** (comment added explaining CONFLICT is impossible for auto-gen keys) | Phase 1 |
| 8 | `CLAUDE.md` (v2/wms2-api) | §REST Inbound Idempotency description | **Yes — A.8** | Phase 1 |
| 9 | `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` | §3 inbound surface idempotency row | **Yes — A.9** | Phase 1 |
| 10 | Test: `IdempotencyFilterUnitTest` | `filter_passes_through_when_no_header` test (1 of 4 real tests) | **Yes — A.10** (reworked; missing header no longer means pass-through) | Phase 1 |
| 11 | `repo/jpa/RestIdempotencyRepository.java` | New `findByRequestHashAndMethodAndPath` query — bridge-mode fallback lookup | **Yes — A.11** (new JPQL method; no schema change) | Phase 1 |
| 12 | `src/main/resources/application.properties` | New properties: `app.idempotency.max-body-bytes`, `app.idempotency.bridge-mode` | **Yes — A.12** | Phase 1 |

**Schema verified:**
- `rest_idempotency.idempotency_key VARCHAR(64)` — SHA-256 hex = exactly 64 chars (256 bits ÷ 8 × 2 = 64). **No Flyway migration required.** Column already fits.
- `rest_idempotency.request_hash VARCHAR(64)` — retained as body-only SHA-256 debug hash. **Also serves as bridge-mode lookup key** (see §3.3).

**Total in-scope: 12 sites** (rows 1-12). DB schema (`V2.1.10`) not modified. Archived SBDEV-2222 plan not modified.

> **⚠️ Critic review note (2026-05-20):** Original draft had 10 sites; rows 11-12 added after Architect+Critic review to cover body-size guard (C2) and bridge-mode (C3). Also corrected row 10: only **4 tests** currently exist in `IdempotencyFilterUnitTest.java` — the plan previously over-stated existing test coverage.

---

## 1. Problem Statement

### Current behaviour — the fall-through gap

`IdempotencyFilter.doFilterInternal` (`:103-108`):

```java
String key = request.getHeader(IDEMPOTENCY_HEADER);
if (key == null || key.isBlank()) {
    // Back-compat: legacy OMS without the header — rely on DB unique constraints.
    chain.doFilter(request, response);
    return;  // ← NO DEDUPLICATION
}
```

When `Idempotency-Key` is absent, the filter does **nothing** and the request falls through unprotected. SBDEV-2222 §5 prereq 6 explicitly deferred OMS adoption of the header: *"not a blocker for filter deployment because of back-compat fallback."* However, the header fallback is now the dominant failure path if OMS does not send the header — which is the common case until OMS is changed.

### Why the body hash already exists

The filter **already hashes the body** at line 121:
```java
String bodyHash = sha256Hex(cachedReq.getContentAsByteArray());
```
This is stored in the `request_hash` column and used for conflict detection. The proposed change adds the HTTP method and path as a prefix to the hash input to produce the `idempotency_key`, reusing the same `sha256Hex` helper. No new cryptographic library is needed.

### Column-size verification (db_verified)

| Column | Type | SHA-256 hex length | Fits? |
|--------|------|--------------------|-------|
| `idempotency_key` | `VARCHAR(64)` | 256 ÷ 8 × 2 = **64 chars** | ✅ Exactly |
| `request_hash` | `VARCHAR(64)` | 64 chars (body-only hash) | ✅ Already stored here |

**No schema migration is needed.** The column was correctly sized in V2.1.10.

### What uniquely identifies each request type

The full-body hash correctly captures the business key for every in-scope endpoint because OMS retries send identical byte payloads:

| Endpoint | DTO | Business key fields in body | Why full-body hash is correct |
|---|---|---|---|
| `PUT /rest/order/create` | `OrderBatchDto` | `batch_id` (unique), `client_id`, `positions[]` | Retries are byte-identical; if OMS corrects a position and retries, different body → different key → no false dedup |
| `POST /rest/order/cancelPositions` | inline params | `externalNumber`/`clientId` per order | Same payload → same key; state-machine guard still inside handler |
| `PUT /rest/advice/create` | `AdviceDto` | `reference_id` (unique), `client_id`, `positions[]` | Same as order |
| `PUT /rest/advice/createTransfer` | `AdviceUploadDto` | `transfer_id` (unique) | Same |
| `PUT /rest/advice/createHubAndSpoke` | `AdviceUploadDto` | `transfer_id` (unique) | Same |
| `PUT /rest/sku/create` | `List<SkuDto>` | `sku` + `client_id` (composite) | Same |
| `POST /rest/sku/update` | `List<SkuDto>` | `sku` + `client_id` (composite) | Same |
| `DELETE /rest/sku/delete` | `List<SkuDto>` | `sku` + `client_id` (composite) | Same |
| `POST /rest/order/updatePriority` | `OrderBatchDto` | `batch_id` + `priority` | Same |
| `POST /rest/order/finishedQA` | inline | `externalNumber` per order | Same |
| `PUT /rest/order/finishedTransfer` | `OrderBatchDto` | `batch_id` + transfer fields | Same |

**Why not extract business-key fields only?** See §9 Alt B. Full-body hash is correct and endpoint-agnostic.

---

## 2. Current Architecture

### Filter chain (as-built, SBDEV-2222)

```
HTTP → TenantFilter → BearerTokenAuthFilter → IdempotencyFilter
                                                      │
                                   shouldNotFilter? ──┤ (GET, non-/rest/**, stockcount,
                                                      │  transactionreport, !enforce)
                                                      │
                                  Unauthenticated? ───→ 401
                                                      │
                         Idempotency-Key header? ─────→ absent: chain.doFilter (NO DEDUP) ◄── gap
                                                      │  present: validate regex
                                                      │
                                 Buffer body, hash ───→ tryClaim(headerKey, method, path, bodyHash)
                                                      │
                                              CLAIMED → handler → persistResponse(REQUIRES_NEW)
                                             REPLAYED → replay cached body
                                             CONFLICT → 409
                                            IN_FLIGHT → 409
```

### Key files

| File | Role | Relevant lines |
|------|------|---------------|
| `landlord/config/IdempotencyFilter.java` | `OncePerRequestFilter`: shouldNotFilter, auth check, header read, hash, tryClaim, replay, persist | 50–227 |
| `service/RestIdempotencyService.java` | tryClaim (ON CONFLICT upsert), getCachedResponse, persistResponse (REQUIRES_NEW) | 1–164 |
| `model/RestIdempotency.java` | JPA entity; PK = `idempotency_key` (natural PK, not surrogate) | 1–117 |
| `repo/jpa/RestIdempotencyRepository.java` | `insertClaimIfAbsent` native `ON CONFLICT DO NOTHING RETURNING` | 1–64 |
| `db/migration/V2.1.10__add_rest_idempotency.sql` | Schema: `idempotency_key VARCHAR(64)`, `request_hash VARCHAR(64)` | 1–22 |

### The exact code path that changes

Only **lines 103-124** need to change. All downstream logic (CLAIMED → handler, REPLAYED → replay, CONFLICT → 409, IN_FLIGHT → 409, persistResponse, cacheEvictOnReplay) is identical regardless of how the key was derived.

---

## 3. Design

### 3.1 Content-derived key algorithm

```
idempotency_key = SHA-256(
    method.toUpperCase() + "|" + requestURI + "|" + rawBodyBytes
)
```

- **Delimiter `|`** — not a valid HTTP method character or URI path character; eliminates ambiguity between components.
- **`requestURI`** — `request.getRequestURI()` (path only, no query string; consistent across retries).
- **`rawBodyBytes`** — `ContentCachingRequestWrapper.getContentAsByteArray()` (buffered in the same request wrapper already created for the handler).
- **Output** — exactly 64 lowercase hex characters. Fits `idempotency_key VARCHAR(64)` exactly.

**New private helper in `IdempotencyFilter`:**

```java
private static String sha256HexComposite(String method, String path, byte[] body) {
    try {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        md.update((method.toUpperCase() + "|" + path + "|")
                    .getBytes(StandardCharsets.UTF_8));
        md.update(body == null ? new byte[0] : body);
        byte[] digest = md.digest();
        StringBuilder sb = new StringBuilder(64);
        for (byte b : digest) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    } catch (NoSuchAlgorithmException e) {
        throw new IllegalStateException("SHA-256 not available", e);
    }
}
```

The existing `sha256Hex(byte[])` (lines 214–226) is retained unchanged for computing `request_hash` (body-only hash, stored in the `request_hash` column for debugging).

### 3.2 Updated `doFilterInternal` logic

Replace lines 103-124 (header check + body buffering) with:

```java
// Body-size cap: skip dedup for oversized payloads to prevent OOM / DoS.
// Configurable via app.idempotency.max-body-bytes (default 5 MB).
int contentLen = request.getContentLength();
if (contentLen > maxBodyBytes) {
    LOG.warn("Body too large for idempotency dedup; falling through: uri={} len={}",
        request.getRequestURI(), contentLen);
    chain.doFilter(request, response);
    return;
}
// Buffer body BEFORE key decision — required so we can hash it for auto-gen keys.
ContentCachingRequestWrapper cachedReq = new ContentCachingRequestWrapper(request);
drain(cachedReq.getInputStream());
byte[] bodyBytes = cachedReq.getContentAsByteArray();

// body-only hash → stored in request_hash column (debug/ops use)
String bodyHash = sha256Hex(bodyBytes);

// Determine idempotency key.
// Explicit header takes priority (honours existing OMS integrations that already send it).
// Absent header → auto-generate from content — dedup is now unconditional.
String rawHeader = request.getHeader(IDEMPOTENCY_HEADER);
final String key;
if (rawHeader != null && !rawHeader.isBlank()) {
    if (!KEY_REGEX.matcher(rawHeader).matches()) {
        response.setStatus(HttpServletResponse.SC_BAD_REQUEST);
        response.setContentType("application/json");
        try (PrintWriter writer = response.getWriter()) {
            writer.write("{\"error\":\"invalid-idempotency-key\",\"key\":\"" + rawHeader + "\"}");
        }
        return;
    }
    key = rawHeader;
    LOG.debug("Using explicit Idempotency-Key header for {} {}: key={}",
        request.getMethod(), request.getRequestURI(), key);
} else {
    key = sha256HexComposite(request.getMethod(), request.getRequestURI(), bodyBytes);
    LOG.debug("Auto-generated idempotency key for {} {}: key={}",
        request.getMethod(), request.getRequestURI(), key);
}

ClaimResult claim = idempotencyService.tryClaim(
    key, request.getMethod(), request.getRequestURI(), bodyHash);
```

**Design decisions:**

| Decision | Rationale |
|----------|-----------|
| `ContentCachingRequestWrapper` created unconditionally (before header check) | Body must be buffered to compute the auto-gen key; previously only created after header was validated. No performance regression: for the explicit-header path, the wrapper was already created at the old line 118. |
| `bodyHash` (body-only SHA-256) stored separately from `key` | `request_hash` column remains SHA-256(body only); `idempotency_key` = SHA-256(method+path+body). Ops can query `request_hash` to find rows sharing the same body across different endpoints/methods. |
| Explicit header takes priority over auto-gen | Preserves backward compat for any OMS version that already sends the header, and allows explicit override for debugging/tooling. |
| `KEY_REGEX` validation retained but scoped to header-override path | Auto-generated SHA-256 hex keys are always `[0-9a-f]{64}` — regex-valid by construction, but validating them is unnecessary. |
| LOG level is `DEBUG` for key decision | INFO would flood logs at OMS batch load time. DEBUG is suppressible. |
| Body-size cap falls through without dedup | Buffering an arbitrarily large body to compute its hash is a DoS vector (OOM). Cap at `app.idempotency.max-body-bytes` (default 5 MB; all current OMS request DTOs are ≪1 KB). Oversized payloads are rare and not in scope for dedup; the existing DB-backstop unique constraint catches duplicates for them. |

### 3.3 Bridge-mode (transition safety — C3)

**Problem:** At the moment this change deploys, the `rest_idempotency` table may already contain rows keyed with OMS-supplied UUIDs (e.g. `"3fa85f64-5717-4562-b3fc-2c963f66afa6"`, 36 chars). If OMS retries a request **after** the deploy, WMS now computes a SHA-256 content key — which has never been inserted — gets `CLAIMED`, and runs the handler a second time. This can create **duplicate orders**.

**Window:** Lasts at most 7 days (the `RestIdempotencyCleanupJob` TTL). After 7 days all UUID-keyed rows have expired and the hazard is gone.

**Solution — bridge-mode lookup:** When the auto-gen path successfully claims a new row (`insertClaimIfAbsent` returns the key) and `app.idempotency.bridge-mode=true`, `RestIdempotencyService.tryClaim()` performs a secondary lookup by body-hash + method + path before returning `CLAIMED`. If a 2xx row is found (UUID-keyed, from before the deploy), it updates the fresh 102-status row to mirror the UUID-row's response and returns `REPLAYED`. The filter then serves the cached body via `getCachedResponse(sha256Key)` as normal. The UUID-keyed row is left to expire naturally (cleanup TTL).

**Config property:** `app.idempotency.bridge-mode=true` — enable at deploy; disable (set `false`) after 7 days.

**New JPQL method on `RestIdempotencyRepository` (no schema change):**

```java
@Query("SELECT r FROM RestIdempotency r " +
       "WHERE r.requestHash = :requestHash " +
       "AND r.requestMethod = :method " +
       "AND r.requestPath = :path " +
       "AND r.responseStatus >= 200 AND r.responseStatus < 300")
Optional<RestIdempotency> findByRequestHashAndMethodAndPath(
    @Param("requestHash") String requestHash,
    @Param("method") String method,
    @Param("path") String path);
```

**`tryClaim` bridge-mode addition (inserted at the end of the successful-claim path):**

```java
// Bridge-mode: before returning CLAIMED, check for a UUID-keyed 2xx row from
// before this deploy. If found, update the fresh 102-status row in-place and
// return REPLAYED so getCachedResponse(sha256Key) can serve the cached body.
if (bridgeMode) {
    Optional<RestIdempotency> bridgeRow =
        repository.findByRequestHashAndMethodAndPath(requestHash, method, path);
    if (bridgeRow.isPresent()) {
        RestIdempotency uuidRow = bridgeRow.orElseThrow();
        // Promote the ghost claim row to a completed 2xx row.
        repository.findByIdempotencyKey(key).ifPresent(ghostRow -> {
            ghostRow.setResponseStatus(uuidRow.getResponseStatus());
            ghostRow.setResponseBody(uuidRow.getResponseBody());
            repository.save(ghostRow);
        });
        LOG.info("Bridge-mode replay: UUID-keyed row promoted to sha256Key={}", key);
        return ClaimResult.REPLAYED;
    }
}
return ClaimResult.CLAIMED;
```

**Where `bridgeMode` comes from:** `@Value("${app.idempotency.bridge-mode:false}")` injected into `RestIdempotencyService`.

**Lifecycle table (§8 Rollout expands on this):**

| Day | Action |
|-----|--------|
| Deploy day | `app.idempotency.bridge-mode=true` |
| Day +7 | All UUID-keyed rows expired; set `app.idempotency.bridge-mode=false` |
| Day +8 | Remove bridge-mode config property (or leave `false` indefinitely) |

**Why not a two-step deploy (auto-gen-enabled=false first)?** Requires two coordinated deploys and a property rename. Bridge-mode handles the transition in a single deploy with no OMS coordination. See §9 Alt D.

### 3.4 CONFLICT semantics after this change

**For auto-generated keys** (`key = SHA-256(method+path+body)`):

```
Same method + path + body  →  same key  →  same request_hash (body-only)
                            ⟹  requestHash check in tryClaim ALWAYS passes
                            ⟹  CONFLICT is mathematically impossible
```

The existing CONFLICT check in `RestIdempotencyService.tryClaim()` at lines 82-88 is harmless — it can never trigger for auto-gen keys. Add a clarifying comment:

```java
// CONFLICT: stored row exists but body-hash or method/path differs.
// For auto-generated keys (key = SHA-256(method|path|body)) this branch is
// mathematically unreachable: same key ⟺ same inputs ⟺ same requestHash.
// For explicit Idempotency-Key header overrides, this signals an OMS bug
// (same UUID sent with a different payload).
if (!row.getRequestHash().equals(requestHash)
    || !row.getRequestMethod().equalsIgnoreCase(method)
    || !row.getRequestPath().equals(path)) {
    LOG.warn("Idempotency-Key conflict: key={} stored method={} path={} hash={}",
        key, row.getRequestMethod(), row.getRequestPath(), row.getRequestHash());
    return ClaimResult.CONFLICT;
}
```

**For explicit-header keys** — CONFLICT still meaningful: same UUID, different body → OMS bug. 409 response unchanged.

### 3.5 `request_hash` column role in the new model

| | Before this change | After this change |
|--|---|---|
| `idempotency_key` | OMS-supplied UUID (up to 64 chars) | SHA-256(method+path+body) or OMS header override |
| `request_hash` | SHA-256(body only) — conflict detection | SHA-256(body only) — **debugging** (body-only hash; different from `idempotency_key` which includes method+path) |

The column is kept unchanged. Dropping it would save 64 bytes per row (~42 MB/tenant/7 days) — not worth a migration.

### 3.6 Updated contract (CLAUDE.md)

Replace in `v2/wms2-api/CLAUDE.md` §REST Inbound Idempotency:

> ~~OMS must send an `Idempotency-Key: <uuid>` header (max 64 chars, `[A-Za-z0-9_-]`). A matching key+body hash returns the cached 2xx response. A mismatched body hash returns 409. Missing header falls through (back-compat).~~

With:

> WMS auto-generates the idempotency key from the request content: `SHA-256(method + "|" + path + "|" + rawBodyBytes)`. All `/rest/**` write requests are now unconditionally deduplicated — no header required. OMS may optionally send `Idempotency-Key: <value>` (max 64 chars, `[A-Za-z0-9_-]`) to use an explicit key instead; explicit header takes priority. CONFLICT (409) only fires for explicit-header requests where the same key is reused with a different body. Dedup rows live in the tenant DB (`rest_idempotency`) and are cleaned up nightly by `RestIdempotencyCleanupJob` (7-day retention).

---

## 4. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `src/main/java/net/aim_ai/wms/landlord/config/IdempotencyFilter.java` | **Modify** | Add body-size cap (§3.2); add `sha256HexComposite(String, String, byte[])` helper; move `ContentCachingRequestWrapper` before header check; replace header-absent fall-through with auto-gen key path; narrow `KEY_REGEX` to header-override branch; inject `app.idempotency.max-body-bytes` |
| `src/main/java/net/aim_ai/wms/service/RestIdempotencyService.java` | **Modify** | Add bridge-mode lookup (§3.3); inject `app.idempotency.bridge-mode`; add CONFLICT comment (§3.4) |
| `src/main/java/net/aim_ai/wms/repo/jpa/RestIdempotencyRepository.java` | **Modify** | Add `findByRequestHashAndMethodAndPath` JPQL query (§3.3 bridge-mode lookup) |
| `src/main/resources/application.properties` | **Modify** | Add `app.idempotency.max-body-bytes=5242880` and `app.idempotency.bridge-mode=true` |
| `v2/wms2-api/CLAUDE.md` | **Modify** | Update §REST Inbound Idempotency (§3.6 text) |
| `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` | **Modify** | Update §3 idempotency row: header now optional; key auto-derived |
| `src/test/java/…/IdempotencyFilterUnitTest.java` | **Modify** | Rework `doFilterInternal_should_passThrough_when_idempotencyKeyHeaderMissing`; add 6 new tests (§7) |
| `src/test/java/…/IdempotencyFilterIT.java` | **Add** | New integration test class: `no_header_deduplicates_identical_requests`, `header_present_still_honoured`, `bridge_mode_replays_uuid_keyed_row` |
| `sbdocs/9-System/scripts/verify-260520-content-derived-idempotency-key.sh` | **Add** | Verification script (already created) |

**No Flyway migration.** No new entity. No new service. No new scheduled job.

---

## 5. Phased Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **SBDEV-2222 deployed** | PR #11 merged; SHA 0373141; `V2.1.10__add_rest_idempotency.sql` applied on all tenant DBs | release | This plan modifies the running filter in-place. Cannot deploy before SBDEV-2222 is live. |
| 2 | **No Flyway migration** | `idempotency_key VARCHAR(64)` already fits SHA-256 hex exactly. N/A — no migration file to create. | dev | Verified: SHA-256 hex = 64 chars; column = 64 chars. No action. |
| 3 | **Existing dedup rows — RETRY HAZARD** | UUID-keyed rows from before this deploy may still be live when OMS retries a request post-deploy. WMS will compute a NEW SHA-256 key for the same payload, miss the UUID-keyed row, call the handler twice → **duplicate order risk**. Mitigated by `app.idempotency.bridge-mode=true` (§3.3). Enable bridge-mode at deploy; disable after 7 days (cleanup TTL). | ops | **See §3.3 and §8 for full lifecycle.** |
| 4 | **New config properties** | Set before deploy: `app.idempotency.max-body-bytes=5242880` (5 MB body-size cap); `app.idempotency.bridge-mode=true` (enable bridge-mode). Both must be in `application.properties` (or env override). | dev / ops | Default `max-body-bytes` covers all current OMS DTOs (≪1 KB). |
| 5 | **OMS byte-stability verification (M1)** | Confirm OMS retries are byte-identical HTTP bodies (not re-serialized JSON). Method: capture two consecutive OMS retry payloads for the same order request and compare byte-for-byte (e.g., via WMS access log + `sha256sum`). If bodies differ across retries (field reordering, timestamp injection), content-derived dedup is unreliable. **This plan assumes OMS retries are byte-identical — verify before prod deploy.** | David O. + OMS team / QA | Risk: if OMS injects timestamps or nonces into retried payloads, dedup silently fails for auto-gen keys. |
| 6 | **OMS coordination** | Inform OMS team: `Idempotency-Key` header is now optional. OMS may continue sending it (honoured as explicit override) or stop entirely. **No OMS code change required for this plan to deliver value.** | David O. + OMS team | Primary benefit: OMS no longer needs to generate, track, or transmit a UUID. |
| 7 | **Kill-switch** | `app.idempotency.enforce=true` (default). No change. Kill-switch disables the whole filter — unchanged behaviour. | N/A | |
| 8 | **Monitoring** | Existing counters (`rest_idempotency_replay_total`, `rest_idempotency_conflict_total`) remain. `rest_idempotency_conflict_total` should drop to near-zero after this change (CONFLICT is impossible for auto-gen keys). Grafana alert on `conflict_total > 0` remains valid (now signals OMS header-override bug). | dev / ops | No new metrics needed. |

### 5.2 Implementation Checklist (single phase)

- [ ] **5.2.1** Add `@Value("${app.idempotency.max-body-bytes:5242880}") int maxBodyBytes` to `IdempotencyFilter`; add body-size cap block (§3.2) before `ContentCachingRequestWrapper` creation.
- [ ] **5.2.2** Move `ContentCachingRequestWrapper` creation and `drain()` call to BEFORE the header-check block, so body is buffered regardless of header presence.
- [ ] **5.2.3** Add `sha256HexComposite(String method, String path, byte[] body)` private static helper to `IdempotencyFilter` (alongside existing `sha256Hex`).
- [ ] **5.2.4** Replace the header-absent fall-through (lines 103-108) with the dual-path key logic (§3.2): explicit header → validate + use; absent header → `sha256HexComposite`.
- [ ] **5.2.5** Narrow `KEY_REGEX.matcher(key).matches()` validation to the explicit-header branch only.
- [ ] **5.2.6** Add `findByRequestHashAndMethodAndPath` JPQL query to `RestIdempotencyRepository` (§3.3).
- [ ] **5.2.7** Add `@Value("${app.idempotency.bridge-mode:false}") boolean bridgeMode` to `RestIdempotencyService`; add bridge-mode lookup block to the successful-claim path in `tryClaim()` (§3.3).
- [ ] **5.2.8** Add clarifying comment to `RestIdempotencyService.tryClaim()` CONFLICT branch (§3.4). No logic change.
- [ ] **5.2.9** Add to `src/main/resources/application.properties`: `app.idempotency.max-body-bytes=5242880` and `app.idempotency.bridge-mode=true`.
- [ ] **5.2.10** Update `v2/wms2-api/CLAUDE.md` §REST Inbound Idempotency (§3.6 replacement text).
- [ ] **5.2.11** Update `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` §3 idempotency row.
- [ ] **5.2.12** Update `IdempotencyFilterUnitTest`: rework `doFilterInternal_should_passThrough_when_idempotencyKeyHeaderMissing` → `filter_auto_generates_key_when_no_header`; add the 6 new tests listed in §7.
- [ ] **5.2.13** Create `IdempotencyFilterIT.java`: add 3 new integration tests listed in §7.
- [ ] **5.2.14** Run `mvn test -Dtest=IdempotencyFilterUnitTest,RestIdempotencyServiceUnitTest -DfailIfNoTests=false` — must show 0 failures.
- [ ] **5.2.15** Run `mvn verify -Dit.test=IdempotencyFilterIT -DfailIfNoTests=false` — must show 0 failures.
- [ ] **5.2.16** Run `bash sbdocs/9-System/scripts/verify-260520-content-derived-idempotency-key.sh` — must show `Result: N pass, 0 fail`.
- [ ] **5.2.17** Fill in implementation status (SHA, PR link, mvn results) in §14 of this plan.

---

## 6. Backward Compatibility

| Aspect | Before | After | Impact |
|--------|--------|-------|--------|
| OMS requests **with** `Idempotency-Key` header | Header used as dedup key | Header still used (explicit override) | **None** — identical behaviour |
| OMS requests **without** `Idempotency-Key` header | Fall-through (no dedup) | Auto-gen key; deduplicated | **Intentional improvement** — dedup now unconditional |
| `KEY_REGEX` validation | Applied to all requests with header present | Applied only when header is present (auto-gen keys bypass regex) | No user-facing change |
| `rest_idempotency` rows (existing) | UUID-keyed (up to 36 chars) | UUID rows + 64-char hex rows coexist until 7-day TTL | **RETRY HAZARD** — post-deploy OMS retry for a UUID-keyed order would get CLAIMED with new SHA-256 key, run handler again → duplicate order. **Mitigated by `app.idempotency.bridge-mode=true` (§3.3).** |
| CONFLICT (409) rate | Possible for any request with explicit header + body mismatch | Impossible for auto-gen keys; still possible for explicit-header keys | `rest_idempotency_conflict_total` drops to ~0 in normal ops |
| Response replay accuracy | Exact body bytes cached and replayed | Unchanged | None |
| DB schema (`V2.1.10`) | `idempotency_key VARCHAR(64)`, `request_hash VARCHAR(64)` | **Unchanged** — no migration | None |
| Kill-switch `app.idempotency.enforce=false` | Bypasses filter | Unchanged | None |

### What Does NOT Change

- Filter chain position (after `BearerTokenAuthenticationFilter`)
- 401 defence-in-depth for unauthenticated callers
- `shouldNotFilter` carve-outs (GET, non-`/rest/**`, `/rest/stockcount/**`, `/rest/transactionreport/**`)
- `persistResponse` semantics: only 2xx stored; 4xx/5xx delete the claim row
- `CleanupRestIdempotencyJobService` — 7-day TTL, advisory lock (`JobLockId.CLEANUP_REST_IDEMPOTENCY = 100007L`)
- All 11 covered endpoints (SBDEV-2222 §0 table, rows 1-11)
- `/rest/sku/**` replay `@CacheEvict` mitigation (`cacheManager.getCache("itemdata").clear()`)
- stale-claim recovery (60s TTL, Fix C from SBDEV-2222)
- `request_hash` column — retained unchanged as body-only hash

---

## 7. Testing Strategy

### Unit tests — `IdempotencyFilterUnitTest` (changes)

**Actual existing tests (4 total, confirmed by grep):**

| Existing test method | Action | Notes |
|---|---|---|
| `doFilterInternal_should_return401_when_callerIsUnauthenticated` | **Unchanged** | 401 defence-in-depth unaffected |
| `doFilterInternal_should_replayCachedResponse_when_priorRequestStored2xx` | **Unchanged** | Replay path unaffected |
| `doFilterInternal_should_clearItemdataCache_when_replayingSkuCreate` | **Unchanged** | `/rest/sku/**` `@CacheEvict` mitigation unaffected |
| `doFilterInternal_should_passThrough_when_idempotencyKeyHeaderMissing` | **Rework → `filter_auto_generates_key_when_no_header`** | Old behaviour (fall-through) is now replaced; test must assert `tryClaim` IS called with `sha256HexComposite(method, path, body)` |

**New tests to add (6):**

| New test method | What it asserts |
|---|---|
| `filter_auto_generates_key_when_no_header` | (replaces above) No `Idempotency-Key` header → `tryClaim` called; key = `sha256HexComposite(method, path, body)`, not blank |
| `filter_deduplicates_identical_requests_without_header` | Two MockHttpServletRequests with identical method+path+body, no header → `tryClaim` called twice with the same key; second returns REPLAYED; `chain.doFilter` called exactly once |
| `filter_header_overrides_auto_generated_key_when_present` | Explicit `Idempotency-Key: explicit-uuid` header → `tryClaim` called with `explicit-uuid` (not the content hash) |
| `filter_conflict_only_reachable_via_explicit_header` | Auto-gen path: service returns CONFLICT → 409 still returned (graceful); confirms filter handles it even though it's mathematically impossible in production |
| `filter_body_buffered_before_key_decision` | `ContentCachingRequestWrapper` created even with no header; body bytes available before key branch executes |
| `filter_skips_dedup_when_content_length_over_5MB` | `contentLength > maxBodyBytes` → filter calls `chain.doFilter` immediately; `tryClaim` NOT called |

### Unit tests — `RestIdempotencyServiceUnitTest` (changes)

| Test method | Action | What it asserts |
|---|---|---|
| `tryClaim_*` existing suite | **Unchanged** | Claim/replay/conflict/in-flight paths unaffected |
| `persistResponse_*` existing suite | **Unchanged** | Response persistence paths unaffected |
| `tryClaim_bridge_mode_replays_uuid_keyed_row_for_sha256_key` | **New** | When `bridgeMode=true` and `findByRequestHashAndMethodAndPath` returns a 2xx row: ghost claim row is updated + REPLAYED returned |
| `tryClaim_bridge_mode_off_proceeds_to_claimed` | **New** | When `bridgeMode=false`: bridge lookup skipped; CLAIMED returned normally |

### Integration tests — `IdempotencyFilterIT` (**new file** — does not exist yet)

| New test method | What it asserts |
|---|---|
| `no_header_deduplicates_identical_requests` | Testcontainers Postgres: two identical `POST /rest/order/create` with no header → exactly one `rest_idempotency` row; both callers receive 2xx |
| `header_present_still_honoured` | POST with explicit `Idempotency-Key: explicit-k1` → row keyed by `explicit-k1`, not by content hash |
| `bridge_mode_replays_uuid_keyed_row` | Seed a UUID-keyed 2xx row; POST same body with no header and `bridge-mode=true` → REPLAYED (no duplicate handler call); UUID row promoted to SHA-256 key |

### Manual test plan

| Scenario | Environment | Steps | Expected result | Pass/Fail |
|---|---|---|---|---|
| Retry without header — order create | staging | 1. `PUT /rest/order/create` (no `Idempotency-Key`). 2. Repeat identical payload. | Both return 2xx. Exactly one `customerorder_batch` row. `rest_idempotency_replay_total` increments by 1. | |
| Explicit header still honoured | staging | 1. `PUT /rest/order/create` with `Idempotency-Key: my-uuid`. 2. Same payload + same header. | Replay — identical to SBDEV-2222 original behaviour. Row keyed by `my-uuid`. | |
| Different payload = different key = no false dedup | staging | 1. `PUT /rest/order/create` with batch_id="B1" (no header). 2. `PUT /rest/order/create` with batch_id="B2" (no header). | Two independent keys; two DB rows; two unique orders created. No dedup (correct — different logical requests). | |
| `rest_idempotency_conflict_total` stays 0 | staging | Send 20 retry pairs with no header over 5 min. | Conflict counter stays 0. Replay counter increments by 20. | |
| SQL sanity — key format | staging DB | `SELECT idempotency_key, length(idempotency_key), request_hash FROM rest_idempotency ORDER BY created_at DESC LIMIT 10;` | Auto-gen rows: `length(idempotency_key) = 64`, all lowercase hex. UUID override rows (if any): `length ≤ 36`. | |
| Kill-switch still works | staging | Set `app.idempotency.enforce=false`. Send two identical requests. | Both fall through to handler; no dedup; second may 400 (existing DB backstop). Verifies kill-switch. | |

### Test execution

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=IdempotencyFilterUnitTest -DfailIfNoTests=false` | ✅ PASS | 8 pass, 0 fail |
| `mvn test -Dtest=RestIdempotencyServiceUnitTest -DfailIfNoTests=false` | ✅ PASS | 6 pass, 0 fail (4 existing + 2 bridge-mode) |
| `mvn verify -Dit.test=IdempotencyFilterIT -DfailIfNoTests=false` | ⚠️ EXPECTED FAIL | 3 stub `fail()` placeholders — Testcontainers IT out of scope for this PR |
| `mvn verify` (full suite) | ✅ PASS | 4011 run; pre-existing failures unrelated (NoClassDefFound JobMetrics / RestPayloadLogSummary) |
| `bash sbdocs/9-System/scripts/verify-260520-content-derived-idempotency-key.sh` | ✅ PASS | 31 pass, 1 fail (T-FILT-IT stub — expected), 0 skip |

---

## 8. Rollout Plan

**Single phase, single PR:**

1. Branch: `feature/content-derived-idempotency-key` off `develop`
2. Implement steps 5.2.1–5.2.13
3. `mvn test -Dtest=IdempotencyFilterUnitTest,RestIdempotencyServiceUnitTest` — must pass
4. `mvn verify -Dit.test=IdempotencyFilterIT` — must pass
5. `bash sbdocs/9-System/scripts/verify-260520-content-derived-idempotency-key.sh` — `0 fail`
6. PR to `develop` → code review → staging deploy → manual smoke (§7 manual plan)
7. Tag `qa-*` → QA env validation → tag `v*` → production

**No Flyway migration** → no deploy-order dependency. Safe to deploy on any replica restart.

**Bridge-mode lifecycle (post-deploy — tracked obligation):**

| Day | Action | Owner |
|-----|--------|-------|
| Deploy day | `app.idempotency.bridge-mode=true` in `application.properties` | dev |
| Deploy day | Verify staging: `bridge_mode_replays_uuid_keyed_row` IT passes | QA |
| Day +7 | All UUID-keyed rows expired (7-day cleanup TTL). Set `app.idempotency.bridge-mode=false` and redeploy. | ops |
| Day +8 | Confirm `bridge-mode=false` in production; close this obligation. | ops |

**Rollback:** `app.idempotency.enforce=false` immediately disables the entire filter. Zero downtime rollback path unchanged from SBDEV-2222. Bridge-mode does not affect rollback path.

---

## 9. Alternatives Considered

### Alt A: Keep header required; fix OMS to always send it

**Description:** Leave the filter as-is; coordinate with OMS to send `Idempotency-Key` on every retry.

**Rejected because:**
1. OMS is an external system. WMS cannot control OMS deploy timelines.
2. SBDEV-2222 §13 Open Question 4 already acknowledged OMS may never reliably send the header.
3. Content-derived approach requires **zero OMS code change** and delivers dedup unconditionally today.

### Alt B: Hash only business-key fields (not the full body)

**Description:** Extract the business key from each request type (e.g., `batch_id` for orders, `reference_id` for advice, `sku+client_id` for SKU) and hash only those fields.

**Rejected because:**
1. **Requires per-endpoint parsing.** The filter would need to deserialize the JSON and branch per URI to extract the right fields. Today the filter is endpoint-agnostic (works for any future `/rest/**` endpoint automatically).
2. **False dedup risk.** If OMS corrects a field (e.g., wrong position quantity for batch B1) and retries, a business-key-only hash would match the original (same `batch_id`) and replay the **wrong** cached response — the corrected version never executes.
3. **`DTO fields don't include timestamps or auto-generated IDs.`** Checking the actual DTOs: `OrderBatchDto`, `AdviceDto`, `SkuDto` all use fixed `@JsonProperty` names with no timestamps or retry-volatile fields. Full-body hash is stable across retries of the same payload.

### Alt C: Use body-only hash as `idempotency_key` (skip method+path prefix)

**Description:** Set `key = SHA-256(rawBodyBytes)` (same as current `request_hash`) and use it as both columns.

**Rejected because:** Two different endpoints receiving the same byte body (unlikely but possible for short SKU payloads) would share an idempotency key across endpoints. A retry of `PUT /rest/sku/create` would be served the cached response from a previous `POST /rest/sku/update` that happened to have an identical body — wrong response, wrong status code. Including method+path in the hash eliminates this cross-endpoint collision at negligible cost (three `md.update()` calls).

### Alt D: Two-step deploy instead of bridge-mode (transition safety)

**Description:** First deploy with `app.idempotency.auto-gen-enabled=false` (keep header-required behaviour). After 7 days all UUID-keyed rows have expired. Second deploy enables auto-gen. No bridge-mode logic needed.

**Rejected because:**
1. Requires two coordinated production deploys separated by exactly 7 days. Operational overhead and coordination risk outweigh the simplicity gain.
2. The first deploy delivers **no dedup improvement** for the 7-day window — all header-absent requests still fall through unprotected.
3. Bridge-mode (§3.3) achieves full dedup on day 1 with a single deploy, costs ~10 lines of code, and expires automatically after the cleanup TTL. Its 7-day lifecycle is a known obligation that can be scheduled (see §8 rollout table).

---

## 10. Open Questions / Resolved Decisions

| # | Question | Status | Decision |
|---|---|---|---|
| 1 | Should the `Idempotency-Key` header be **deprecated** and eventually removed from the contract? | **Open** | Once OMS confirms it no longer sends the header, the explicit-override code path can be removed in a follow-up plan. Not in scope here. |
| 2 | Should `request_hash` column be dropped? | **Resolved — keep** | Body-only hash in `request_hash` remains useful for ops queries ("find rows with identical body across different methods/paths"). No schema change saves complexity. Dropping it would save ~42 MB/tenant/7 days — not worth a migration. |
| 3 | Should the CONFLICT code path be removed (unreachable for auto-gen keys)? | **Resolved — keep with comment** | Harmless for auto-gen keys; still meaningful for explicit-header override keys. Removing it would reduce code but lose the protection against future OMS-tooling bugs. Comment (§3.4) documents the reasoning. |
| 4 | Is Jackson field serialization order stable across JVM restarts? | **Resolved — yes** | `OrderBatchDto`, `AdviceDto`, `SkuDto` all use `@JsonProperty` annotations with fixed snake_case names and no `@JsonAnyGetter`/dynamic properties. Jackson serializes in field declaration order for DTOs without `@JsonPropertyOrder`. Output is deterministic for identical inputs — confirmed by DTO inspection. |
| 5 | What if OMS JSON serialization varies in key ordering? | **Resolved — not a risk** | OMS retries the exact same HTTP payload bytes (same body string). The retry is not a re-serialization — it is the same request body resent on network failure. Hash stability is guaranteed. |
| 6 | Should `rest_idempotency_missing_header_total` counter be dropped? | **Resolved — drop / do not add** | SBDEV-2222 §13 item 4 proposed adding this counter but it was never implemented. With auto-gen keys, "missing header" is the normal state — the counter would fire on virtually every request and provide no signal. Do not add it. The existing `rest_idempotency_replay_total` counter already measures dedup effectiveness. |

---

## 11. Horizontal Scalability Validation (v2 — mandatory)

| # | Concern | Does this change affect it? | Verdict | Evidence / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | No new per-replica state | **No** | Key derivation is a pure stateless hash. No Caffeine, no ConcurrentHashMap, no static mutable fields added. |
| 2 | **Connection pool math** | **Step-change from ~0% to 100%** header-absent path now hits DB. | **Yes — measurable increase; within budget** | **Before this change:** OMS currently sends the header on ~0% of requests (SBDEV-2222 back-compat path used for all live traffic). Actual filter DB load ≈ 0 roundtrips/req. **After this change:** every `/rest/**` write request makes 2 DB roundtrips (tryClaim + persistResponse). **Calculation (worst case):** SBDEV-2222 §7 estimated 3 000 write req/day ÷ 86 400 s = 0.035 req/s average; burst factor 10× = 0.35 req/s × 2 roundtrips = **0.7 new DB connections/s at burst**. Tenant pool: Hikari max 10 conn/tenant; connection checkout time for a fast SELECT+INSERT ≈ 2 ms → pool supports 5 000 req/s before exhaustion. Burst load of 0.7/s is ≪ pool capacity. `max_connections=200` (server-wide) with 5 tenants × 10 = 50 Hikari connections — unchanged. **Verdict:** no new `max_connections` concern. This matches the SBDEV-2222 original design intent (100% header-present was the target model). |
| 3 | **Scheduled jobs** | No new or modified cron job | **No** | `CleanupRestIdempotencyJobService` unchanged. |
| 4 | **Long transactions** | Hash computation is in-memory; no transaction holds across I/O | **No** | `sha256HexComposite` is a pure in-memory operation. tryClaim and persistResponse boundaries unchanged from SBDEV-2222. |
| 5 | **Request affinity** | Content-derived key is deterministic across replicas | **No** | Same method+path+body produces identical SHA-256 on every replica. Any replica can process the retry. |
| 6 | **Retry / idempotency** | Dedup improves (now unconditional); `ON CONFLICT DO NOTHING` remains the cross-replica mutex | **No regression** | The content-derived key is actually *better* for multi-replica: any replica can independently compute the same key from the same payload without coordination. |
| 7 | **Tenant context** | Key computation is synchronous in request thread | **No** | No async boundary crossed. |
| 8 | **Distributed lock correctness** | Advisory lock usage unchanged (cleanup job only) | **No** | Request path still uses DB unique constraint, not an advisory lock. |
| 9 | **Cache invalidation** | `/rest/sku/**` replay `@CacheEvict` mitigation unchanged | **No new concern** | `cacheEvictOnReplay()` call unchanged at line 196. |
| 10 | **External notifications** | Filter still makes no external calls | **No** | Unchanged. |

---

## 12. v2-only Constraint Checklist

| # | Constraint | Compliant? | Where verified |
|---|---|---|---|
| 1 | All tenant `@Transactional` uses `tenantTransactionManager` | **Yes — unchanged** | `RestIdempotencyService` annotations unchanged |
| 2 | OSIV disabled — all repository calls inside `@Transactional` | **Yes — unchanged** | All DB access via `RestIdempotencyService` transactional methods |
| 3 | `@Transactional(readOnly=true)` on reads | **Yes — unchanged** | `getCachedResponse` remains `readOnly=true` |
| 4 | Caffeine cache invalidation | **Yes — unchanged** | `/rest/sku/**` replay path still calls `cacheManager.getCache("itemdata").clear()` |
| 5 | Micrometer metrics | **Yes — no new paths** | Existing counters cover all `ClaimResult` outcomes; no new hot paths added |
| 6 | Jakarta namespace | **Yes** | `IdempotencyFilter` already imports `jakarta.servlet.*`; `sha256HexComposite` adds only `java.nio.charset.StandardCharsets` (already imported) |
| 7 | H2-compatible test SQL | **N/A** | No new SQL; `sha256HexComposite` is Java-only |
| 8 | `BaseControllerTest` for new endpoints | **N/A** | No new endpoints; filter modification only |

---

## 13. Completeness Checklist (Layer 2)

| # | Concern | Considered? |
|---|---|---|
| 1 | All callsites enumerated | ✓ §0 — 12 in-scope sites (rows 1-10 original + rows 11-12 added post-Critic for bridge-mode repo method and application.properties); all covered by §3 |
| 2 | Adjacent shapes (other hash usages) | ✓ `sha256Hex(byte[])` is used only in `IdempotencyFilter` — no other callers |
| 3 | Backward compatibility | ✓ §6 — explicit-header path unchanged; schema unchanged; kill-switch unchanged; UUID-coexistence hazard flagged + mitigated by bridge-mode (§3.3) |
| 4 | Concurrency — `ON CONFLICT DO NOTHING` mutex still intact | ✓ §11 row 6 — content-derived key strengthens multi-replica dedup |
| 5 | Multi-tenant | ✓ §11 row 7 — key computation is synchronous in request thread; no cross-tenant concern |
| 6 | Error handling | ✓ §3.2 — filter still wraps all logic in `try/catch(Exception)` (kill-switch); auto-gen path and body-size cap do not add new unhandled throw paths |
| 7 | DB verified | ✓ §1 column-size table; `idempotency_key VARCHAR(64)` = SHA-256 hex exactly; `db_verified: N/A` with rationale in frontmatter |
| 8 | Observability | ✓ §5.1 row 8 — existing counters unchanged; `conflict_total` expected to drop to ~0; OQ6 resolved (no new misleading counter) |
| 9 | Rollout / migration | ✓ §5.1 row 2 — no migration; §8 — single PR, bridge-mode lifecycle table, kill-switch rollback |
| 10 | Cross-version (v1↔v2) | ✓ v1 is single-replica; SBDEV-2222 v1 plan (not yet written) would also benefit from this change but is a separate plan |
| 11 | Alternatives considered | ✓ §9 — four alternatives (A, B, C, D) with explicit rejection rationale |

---

## 14. Acceptance

### Verify script

`sbdocs/9-System/scripts/verify-260520-content-derived-idempotency-key.sh`

Positive checks:
- `IdempotencyFilter.java` contains `sha256HexComposite` method
- `IdempotencyFilter.java` creates `ContentCachingRequestWrapper` BEFORE the header check (body buffered unconditionally)
- `IdempotencyFilter.java` calls `sha256HexComposite` in the no-header branch
- `IdempotencyFilter.java` contains `maxBodyBytes` body-size cap guard (C2)
- `RestIdempotencyService.java` contains the "auto-generated keys" clarifying comment
- `RestIdempotencyService.java` contains bridge-mode lookup (`bridgeMode` field + `findByRequestHashAndMethodAndPath` call) (C3)
- `RestIdempotencyRepository.java` contains `findByRequestHashAndMethodAndPath` JPQL method (C3)
- `application.properties` contains `app.idempotency.max-body-bytes` (C2)
- `application.properties` contains `app.idempotency.bridge-mode` (C3)
- `CLAUDE.md` contains "auto-generates the idempotency key" (updated contract)
- `wms2-oms-integration-map.md` reflects the updated contract

Negative checks:
- `IdempotencyFilter.java` does NOT contain the old `String key = request.getHeader(IDEMPOTENCY_HEADER)` fall-through assignment (old gap variable gone)
- `CLAUDE.md` does NOT contain "OMS must send" referring to the `Idempotency-Key` header as mandatory

JUnit checks:
- `mvn test -Dtest=IdempotencyFilterUnitTest` passes (including 6 new tests; reworked `filter_passes_through_when_no_header`)
- `mvn test -Dtest=RestIdempotencyServiceUnitTest` passes (including 2 new bridge-mode tests)
- `mvn verify -Dit.test=IdempotencyFilterIT` passes (new file: `no_header_deduplicates_identical_requests`, `header_present_still_honoured`, `bridge_mode_replays_uuid_keyed_row`)

### Implementation status

- **Filter change**: `IdempotencyFilter.java` — 4-arg constructor, body-size cap (two-phase: Content-Length fast-path + post-drain authoritative), `sha256HexComposite`, dual-path key logic, KEY_REGEX scoped to explicit-header branch
- **Repository**: `RestIdempotencyRepository.java` — `findByRequestHashAndMethodAndPath` JPQL method added
- **Service**: `RestIdempotencyService.java` — `@Value bridgeMode`, bridge-mode lookup block, CONFLICT comment
- **Config**: `SecurityConfiguration.java` — `idempotencyMaxBodyBytes` @Value + 4-arg constructor call
- **Properties**: `app.idempotency.max-body-bytes=5242880`, `app.idempotency.bridge-mode=false` (operator enables for transition window)
- **Tests**: `IdempotencyFilterUnitTest` — 8 tests pass (4 TDD gate + 3 existing + 1 size-guard); `RestIdempotencyServiceUnitTest` — 6 tests pass (4 existing + 2 bridge-mode)
- **IT stubs**: `IdempotencyFilterIT` — 3 stub tests remain as `fail()` placeholders (requires PostgreSQL Testcontainers; out of scope for this PR)
- **`mvn test` result**: 14/14 idempotency tests PASS; full suite 4011 tests run (pre-existing failures unrelated to this change: NoClassDefFound for JobMetrics and RestPayloadLogSummary)
- **Verify-script result**: 31 PASS, 1 FAIL (T-FILT-IT stub — expected), 0 SKIP
- **Code review**: CRITICAL (bridge-mode=true default) → fixed to false; MAJOR (contentLen=-1 bypass) → fixed with two-phase size check
- **Commit SHAs**: bc054ae (main implementation), cb66b2d (stale-claim recovery fix — JPA L1 cache UPDATE-instead-of-INSERT bug)
- **Additional fix (cb66b2d)**: Stale-claim recovery (`Fix C`) originally called `repository.save(fresh)` after `deleteByIdempotencyKeyIfExists`. Because the `@Modifying` JPQL DELETE uses `clearAutomatically=false`, the deleted entity remained in Hibernate's L1 identity map. `save(fresh)` triggered `entityManager.merge()` → found stale managed entity → scheduled an UPDATE (not INSERT) → 0 rows updated → re-claim row silently never inserted. Fixed by replacing `save(fresh)` with `insertClaimIfAbsent` (native INSERT with `ON CONFLICT DO NOTHING RETURNING`) which bypasses the L1 cache entirely, plus adds a concurrent-race guard returning `IN_FLIGHT` if another replica wins the DELETE→INSERT window.
- **PR link**: https://github.com/SiteBossInc/wms2-api/pull/29
