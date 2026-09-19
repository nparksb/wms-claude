---
name: pgjdbc-wedged-db-is-bounded-not-infinite
description: A wedged tenant DB does NOT hang wms2 forever — measured 11-21s per tenant per attempt; socketTimeout=0 only leaves POST-handshake reads unbounded
metadata:
  type: reference
---

`socketTimeout=0` / `loginTimeout=0` are pgjdbc's real defaults, but inferring "therefore a
wedged host hangs forever" is **false**. Measured on pgjdbc 42.7.8 (SBDEV-3204, 2026-09-02),
seconds to failure with **no properties set**, for the two connects wms2 makes per tenant
(raw `resolveWarehouseTz` probe, then `new HikariDataSource` at `connectionTimeout=30000`):

| shape | connect 1 | connect 2 | pair |
|---|---|---|---|
| SYN dropped (192.0.2.1) | 10.23s | 11.10s | **21.3s** |
| TCP accepted, then silence | 5.29s | 6.08s | **11.4s** |

- 10.2s = pgjdbc's documented `connectTimeout` default of 10 (set it to 3 → 3.02s).
- 5.3s = **no identified mechanism**; `connectTimeout` does NOT govern it (set to 3 → still
  5.03s), but `socketTimeout=2` and `loginTimeout=2` both do.
- So SBDEV-3191's boot probe terminates: 4 UAT tenants down × 60 attempts ⇒ ERROR in
  **~45–85 min**, not never. Its old "~40s/tenant, ~2.7h" was also wrong — it assumed
  connect 2 burns the full 30s Hikari timeout; measured, it fails when the driver does.

**Genuinely unbounded, but UNREPRODUCED:** a *post-handshake* read — connect + auth succeed,
then the DB stalls mid-query. A bare `ServerSocket` can't test it (needs the PG wire protocol).
Parked as SBDEV-3204 `pending`/low.

⚠️ **Never set a pool-wide `socketTimeout`.** It's a per-read timeout on every statement =
a global query timeout. `StockSummaryExportJob` streams a cursor over every `itemdata` row.
Bound *establishment* on the pool (`connectTimeout`/`loginTimeout`); read timeouts only on the
one-shot probe. The fix needs **no** landlord data change — the landlord schema has no
connect/socket timeout column anywhere (only Hikari's `connection_timeout_ms`/`idle_timeout_ms`),
and it's the single `DriverManager.getConnection` in all of `src/main`.

See [[a-zero-scan-needs-a-positive-control]] — same failure family: a plausible inference that
agreed with what we expected, never instrumented. Caught only by a discrimination assertion
([[green-tests-that-prove-nothing]]).
