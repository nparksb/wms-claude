---
name: wms2-idempotency-filter-caches-rest-200-failures
description: "IdempotencyFilter caches any 2xx on /rest/** — a 200 \"status:failure\" body replays to OMS's identical re-send for 7 days; only cancelPositions is excepted (SBDEV-3729)"
metadata:
  node_type: memory
  type: project
  originSessionId: 8ba50089-49fb-4127-9271-10ab67b75ecb
  modified: 2026-10-11T23:20:10.719Z
---

`IdempotencyFilter` keys `/rest/**` writes on a body hash (OMS sends no Idempotency-Key), and caches EVERY 2xx response. Its "a 200 carrying errors is a failure — drop the claim row" rule (G-e) originally applied only to `/v3/stockUnit/transferStock`.

So any `/rest` handler that answers a partial failure with HTTP 200 + `"status":"failure"` gets that failure replayed to OMS's identical re-send for 7 days, and the handler never runs again. SBDEV-3339's "re-send retries only the failed orders" claim for `cancelPositions` was false because of this. Fixed in SBDEV-3729 (PR #505) for `/rest/order/cancelPositions` only, via `REST_FAILURE_STATUS_PATHS`. Other `/rest` paths still cache their 2xx bodies, and a test pins that scope.

**Why:** a security review lane found it only because SBDEV-3729 moved lost-race failures from an uncached 400 onto the cached 200 path.

**How to apply:** any time a `/rest` handler is made to return 200-with-failure (instead of 4xx), add its path to `REST_FAILURE_STATUS_PATHS`, or retries silently stop. Deploying such a change: purge cached failures first (`rest_idempotency.response_body like '%"status":"failure"%'`). Related: [[wms2-rest-surface-internal-only-jwt-deferred]].
