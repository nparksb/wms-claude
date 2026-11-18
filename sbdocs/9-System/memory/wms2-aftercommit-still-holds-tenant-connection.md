---
name: wms2-aftercommit-still-holds-tenant-connection
description: "MEASURED 2026-11-11 — inside afterCommit the tenant JDBC connection is still checked out; afterCommit frees row locks, NOT the pool slot"
metadata:
  node_type: memory
  type: project
  originSessionId: 13e35dc8-e608-4d1f-a2e2-c3bd698308ff
  modified: 2026-11-11T11:54:39.312Z
---

In wms2-api, a `TransactionSynchronization.afterCommit` body runs while the transaction's JDBC connection is still checked out. Spring's default `DELAYED_ACQUISITION_AND_HOLD` applies (no `hibernate.connection.handling_mode` override), and the connection is only given back at `cleanupAfterCompletion`. An HTTP call there (`OmsNotificationService.sendAfterCommit`, a CUPS print) pins a tenant pool slot for its whole duration. Commit releases the row locks; the connection stays held.

Measured by `TenantConnectionReleasedBeforeAfterCommitIT` (SBDEV-4108 B): `afterCommit[closed=false alive=true]`. Two instruments: `Connection.isClosed()`, and the backend pid in `pg_stat_activity` read over a separate connection, each with an in-transaction positive control. Evidence: `sbdocs/4-Archieves/wms2/plan/SBDEV-4108-evidence/partB-measurement.md`. The probe source sits beside it (kept off the branch because it is red by design).

**Why:** SBDEV-3674's architect note had claimed the opposite (that `afterTransaction()` releases the connection), and that claim reasoned a pool-cost delta to zero.

**How to apply:** never cite afterCommit as "connection-free" in a pool or slot argument. The fix is proposal **P90** (T3, Nam split it out 2026-11-11). Its preferred shape is moving the senders to the outbox. Reuse the probe IT as P90's regression test. Related: [[pool-exhaustion-counts-slots-not-milliseconds]], [[wms2-sendaftercommit-guard-is-inverted]].
