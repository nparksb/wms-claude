---
name: dev-lock-race-harness
description: "How to force a lock-wait race against the deployed dev API (scanGate etc.) — 3 s lock_timeout, confirm holder lock first, server-side DO coordinator with pg_stat_clear_snapshot"
metadata:
  node_type: memory
  type: reference
  originSessionId: 55a36462-dfbc-4741-bba5-da0fe5de670a
  modified: 2026-11-08T11:13:46.167Z
---

Recipe that worked on 2026-11-08 (SBDEV-4072 dev test) for "writer commits while the API request waits on a row lock":

1. **Holder** (q.sh, background): `begin; select ... for no key update; select pg_sleep(9); commit;`
2. **Confirm the holder's lock is held BEFORE sending the API call** (pg_locks transactionid for the pg_sleep(9) session). A fixed `sleep 1` head start was not enough: q.sh's connect lost the race, the request never waited and did a REAL truck load (OMS notified, reverted by SQL on Nam's go).
3. **Coordinator = one server-side `DO` block**, not separate psql calls: dev's tenant `lock_timeout` is **3000 ms** (SBDEV-3398, SET LOCAL per tx), and separate q.sh calls take ~0.5–1 s each, so the request times out into the lockContention refusal. Inside the DO loop call `perform pg_stat_clear_snapshot()` each iteration, or pg_stat_activity is frozen for the transaction and never shows the waiter. Then the writer change, `commit;` (allowed in a top-level DO), then `pg_cancel_backend` the holder. That finished in ~470 ms.
4. Fail-safe property: if any step misses, the request just times out into a refusal; never cancel the holder unless the writer step committed.

Also: `billoflading.name` (not `number`) is what scanGate's `selectedBOLName` resolves (`findIdByName`). See [[wms-dev-probe]].
