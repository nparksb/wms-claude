# PgBouncer Connection Pool Strategy for Horizontal Scalability

**Date:** 2026-04-05
**Parent plan:** [260424-WMS_API_Problem_Areas_Analysis_And_Refactoring_Plan.md](../../../4-Archieves/wms2/plan/260424-WMS_API_Problem_Areas_Analysis_And_Refactoring_Plan.md) — Section 4.3.3, Option A
**Status:** Pending

---

## Problem

N replicas × T tenants × maxPoolSize exceeds PostgreSQL `max_connections`.

The WMS API creates a separate HikariCP connection pool per tenant (on-demand via `TenantDynamicRoutingDataSource`). Each pool has a configurable `maxPoolSize` (default 2, fallback 5). When multiple API replicas are deployed for horizontal scalability, each replica creates its own set of pools — and the total connections multiply.

**Example:** 3 replicas × 20 active tenants × 5 max connections = **300 connections** to PostgreSQL. With a typical `max_connections=100`, this fails with connection exhaustion errors.

## Current Architecture

```
[Replica 1] ── tenant-A HikariCP pool (maxPoolSize=5) ──┐
[Replica 2] ── tenant-A HikariCP pool (maxPoolSize=5) ──┼── [PostgreSQL tenant-A (max_connections=100)]
[Replica 3] ── tenant-A HikariCP pool (maxPoolSize=5) ──┘
```

### Current connection pool configuration

**Tenant pool creation:** `TenantDynamicRoutingDataSource.java` (lines 70-95)

Each tenant gets a separate `HikariDataSource` created on-demand via `computeIfAbsent()` in a `ConcurrentHashMap<String, HikariDataSource>`.

**Per-tenant pool parameters** (stored in landlord DB table `tenant_db_configuration`):

| Column | Type | Default | Purpose |
|--------|------|---------|---------|
| `max_pool_size` | Integer | 2 | Maximum connections per tenant pool |
| `min_idle` | Integer | 0 | Minimum idle connections |
| `idle_timeout_ms` | Integer | 60000 | Idle connection timeout (ms) |
| `connection_timeout_ms` | Integer | 30000 | Connection acquisition timeout (ms) |

**Hardcoded HikariCP defaults** (when DB value is null):

| Parameter | Value | Location |
|-----------|-------|----------|
| maxPoolSize | 5 | `TenantDynamicRoutingDataSource.java:77` |
| minIdle | 1 | Line 78 |
| idleTimeout | 600000ms (10 min) | Line 79 |
| connectionTimeout | 30000ms (30 sec) | Line 80 |
| maxLifetime | 1800000ms (30 min) | Line 86 |
| leakDetectionThreshold | 60000ms (60 sec) | Line 87 |
| validationTimeout | 5000ms (5 sec) | Line 88 |
| keepaliveTime | 300000ms (5 min) | Line 89 |
| autoCommit | false | Line 83 |

**Pool lifecycle:** `TenantPoolEvictor.java` runs every 5 minutes and evicts tenant pools idle for >15 minutes.

**No hard limit** on concurrent active tenants — the system grows unbounded and relies on eviction to manage pool count.

## Target Architecture with PgBouncer

```
[Replica 1] ── HikariCP (maxPoolSize=2) ──┐
[Replica 2] ── HikariCP (maxPoolSize=2) ──┼── [PgBouncer (pool_size=30)] ── [PostgreSQL (max_connections=50)]
[Replica 3] ── HikariCP (maxPoolSize=2) ──┘
```

PgBouncer sits between all API replicas and PostgreSQL. It caps total server connections regardless of how many replicas connect.

**Math:** 3 replicas × 20 tenants × 2 connections = 120 HikariCP connections → PgBouncer multiplexes down to 30 actual PostgreSQL connections.

---

## Implementation Plan

### Step 1: Deploy PgBouncer (Infrastructure)

**Effort:** Medium | **Risk:** Low | **Code changes:** None

#### 1.1 PgBouncer configuration (`pgbouncer.ini`)

```ini
[databases]
# One entry per tenant database — point each to its PostgreSQL host
# Option A: Explicit entries
tenant_acme_wh01 = host=pg-host port=5432 dbname=acme_wh01
tenant_acme_wh02 = host=pg-host port=5432 dbname=acme_wh02

# Option B: Wildcard (if all tenants on same PostgreSQL server)
# * = host=pg-host port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

# CRITICAL: Must use 'transaction' mode
# Releases server connection back to pool after each transaction completes.
# Required because WMS API uses @Transactional boundaries.
pool_mode = transaction

# Total server connections PgBouncer will open to PostgreSQL (the hard cap)
default_pool_size = 30

# Burst capacity
max_db_connections = 40

# Client-side capacity (how many HikariCP connections PgBouncer accepts)
max_client_conn = 200

# Required for transaction mode with prepared statements (PgBouncer 1.21+)
max_prepared_statements = 100
```

#### 1.2 Authentication file (`userlist.txt`)

```
"wms_tenant_user" "md5<hash>"
```

One entry per tenant database user credential.

#### 1.3 Deployment options

| Environment | Approach |
|-------------|----------|
| **Kubernetes** | Deploy PgBouncer as a sidecar container in the PostgreSQL pod, or as a separate `Deployment` + `Service` |
| **Docker Compose** | Add a PgBouncer service container in front of PostgreSQL |
| **Bare metal** | Install PgBouncer on the same host as PostgreSQL or on a dedicated proxy host |

#### 1.4 PgBouncer version requirement

- **PgBouncer 1.21+** recommended for `max_prepared_statements` support in transaction mode
- If using an older version, prepared statement caching must be disabled on the HikariCP side (see Step 3)

### Step 2: Update Tenant Database URLs (Data change)

**Effort:** Low | **Risk:** Low | **Code changes:** None

Update `db_url` in the landlord database `tenant_db_configuration` table to point through PgBouncer instead of directly to PostgreSQL:

```sql
-- Before: direct to PostgreSQL
-- db_url = 'jdbc:postgresql://pg-host:5432/acme_wh01'

-- After: through PgBouncer
UPDATE tenant_db_configuration 
SET db_url = REPLACE(db_url, 'pg-host:5432', 'pgbouncer-host:6432')
WHERE db_url LIKE '%pg-host:5432%';
```

**Note:** If using PgBouncer database aliases (Option A in 1.1), the database name in the JDBC URL must match the `[databases]` entry name.

### Step 3: Reduce HikariCP Pool Sizes (Data change)

**Effort:** Low | **Risk:** Low | **Code changes:** None

With PgBouncer handling connection multiplexing, each HikariCP pool only needs enough connections for its own concurrent queries — not for overall capacity.

```sql
-- Reduce pool sizes for PgBouncer multiplexing
UPDATE tenant_db_configuration 
SET max_pool_size = 2,
    min_idle = 0,
    idle_timeout_ms = 30000   -- 30 seconds (PgBouncer handles keepalive)
WHERE max_pool_size > 2;
```

### Step 4: Lower Hardcoded Fallback Default (Optional code change)

**Effort:** Very Low | **Risk:** Very Low | **Code change:** 1 line

In `TenantDynamicRoutingDataSource.java:77`, the fallback when `maxPoolSize` is null is `5`. Lower it to `2` so new tenants without explicit config don't over-allocate:

**File:** `src/main/java/net/aim_ai/wms/landlord/config/TenantDynamicRoutingDataSource.java`

```java
// Before
cfg.setMaximumPoolSize(tc.getMaxPoolSize() != null ? tc.getMaxPoolSize() : 5);

// After
cfg.setMaximumPoolSize(tc.getMaxPoolSize() != null ? tc.getMaxPoolSize() : 2);
```

This change is optional if all tenant configs in the DB already have `max_pool_size` set.

### Step 5: Handle Prepared Statements (Conditional)

**Effort:** Very Low | **Risk:** Low | **Code change:** 3 lines (only if PgBouncer < 1.21)

PgBouncer in `transaction` mode historically had issues with prepared statements. Modern PgBouncer (1.21+) supports `max_prepared_statements` which resolves this.

**If using PgBouncer < 1.21**, disable HikariCP-side prepared statement caching in `TenantDynamicRoutingDataSource.createHikariPool()`:

```java
// Comment out or remove these lines:
// cfg.addDataSourceProperty("cachePrepStmts", "true");
// cfg.addDataSourceProperty("prepStmtCacheSize", "250");
// cfg.addDataSourceProperty("prepStmtCacheSqlLimit", "2048");
```

**If using PgBouncer 1.21+**, no change needed — keep the caching enabled for better performance.

---

## Sizing Guide

| Parameter | Formula | Example (3 replicas, 20 active tenants) |
|-----------|---------|----------------------------------------|
| HikariCP `maxPoolSize` per tenant | 2 (minimum viable) | 2 |
| Total HikariCP connections (all replicas) | replicas × tenants × maxPoolSize | 3 × 20 × 2 = 120 |
| PgBouncer `default_pool_size` | Expected peak concurrent queries per tenant DB | 30 |
| PgBouncer `max_client_conn` | >= total HikariCP connections | 200 |
| PostgreSQL `max_connections` | PgBouncer pool_size + overhead (superuser, monitoring) | 50 |

### Scaling table

| Replicas | Active Tenants | HikariCP maxPoolSize | Total HikariCP Conns | PgBouncer pool_size | PostgreSQL max_connections |
|----------|---------------|---------------------|---------------------|--------------------|--------------------------| 
| 1 | 10 | 5 | 50 | N/A (not needed) | 100 |
| 2 | 20 | 3 | 120 | 30 | 50 |
| 3 | 20 | 2 | 120 | 30 | 50 |
| 5 | 30 | 2 | 300 | 40 | 60 |
| 10 | 50 | 2 | 1000 | 50 | 80 |

---

## Monitoring

### PgBouncer monitoring

| Metric | How to check | Alert threshold |
|--------|-------------|----------------|
| Clients waiting for connection | `SHOW POOLS` → `cl_waiting` column | > 0 for > 30 seconds |
| Active server connections | `SHOW POOLS` → `sv_active` column | > 80% of `default_pool_size` |
| Average query time | `SHOW STATS` → `avg_query_time` | Baseline + 50% |
| Total client connections | `SHOW POOLS` → `cl_active + cl_waiting` | > 80% of `max_client_conn` |

Access PgBouncer admin console: `psql -h pgbouncer-host -p 6432 -U pgbouncer pgbouncer`

### HikariCP monitoring (application side)

Expose via Spring Actuator `/actuator/metrics/hikaricp.*`:

| Metric | Meaning |
|--------|---------|
| `hikaricp.connections.active` | Currently in-use connections |
| `hikaricp.connections.pending` | Threads waiting for a connection |
| `hikaricp.connections.timeout.total` | Connection acquisition timeouts (should be 0) |

### Tenant pool monitoring

Monitor `TenantDynamicRoutingDataSource.tenantPools.size()` to track how many tenant pools are active at any time. Consider exposing this via a custom actuator endpoint.

---

## Rollback Plan

Since this is primarily an infrastructure + data change:

1. **Revert `db_url`** entries in landlord DB back to direct PostgreSQL URLs
2. **Restore `max_pool_size`** values to previous settings
3. **PgBouncer** can be left running but unused, or shut down
4. **Revert code change** (Step 4) if applied — single line

**Rollback time:** < 5 minutes (SQL updates + application restart to pick up new config).

---

## Validation Checklist

- [ ] PgBouncer deployed and accepting connections on port 6432
- [ ] `pool_mode = transaction` confirmed in PgBouncer config
- [ ] Tenant `db_url` entries updated to point to PgBouncer
- [ ] Tenant `max_pool_size` reduced to 2
- [ ] Application starts successfully and routes tenant queries through PgBouncer
- [ ] PgBouncer `SHOW POOLS` shows expected connection counts
- [ ] Load test with N replicas confirms `max_connections` not exceeded
- [ ] `cl_waiting = 0` under normal load
- [ ] Prepared statements work correctly (verify via application logs — no SQL errors)
- [ ] Pool eviction still works (tenant pools evicted after 15 min idle)
- [ ] Flyway migrations still run (may need direct PostgreSQL URL, not PgBouncer)

---

## Known Considerations

### Flyway migrations

Flyway migrations may not work correctly through PgBouncer in transaction mode because migrations can use session-level features (e.g., `SET` commands, advisory locks). Consider:
- Running migrations with a direct PostgreSQL URL (bypassing PgBouncer)
- Using a separate PgBouncer config with `pool_mode = session` for migration connections

### Long-running transactions

`runClubLine` holds a transaction for an entire batch. In PgBouncer transaction mode, the server connection is held for the full transaction duration. This is expected and correct — PgBouncer only multiplexes between transactions, not within them. Monitor `sv_active` during batch processing.

### Connection warm-up

After PgBouncer restart, all server connections need to be re-established. This can cause a brief latency spike. Consider using PgBouncer's `min_pool_size` to maintain warm connections.

---

## Scope note

This document is an implementation plan only. No changes have been applied.
