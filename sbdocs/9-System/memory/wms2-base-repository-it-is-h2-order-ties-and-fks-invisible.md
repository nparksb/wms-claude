---
name: wms2-base-repository-it-is-h2-order-ties-and-fks-invisible
description: wms2-api BaseRepositoryIntegrationTest runs on H2 — an ORDER BY tiebreak mutant survives there and FKs are not enforced; pin ordering/joins on BasePostgresIntegrationTest
metadata:
  node_type: memory
  type: feedback
  originSessionId: 2366fafd-f8aa-4ab4-9575-c91717d4d38b
  modified: 2026-10-16T18:06:39.246Z
---

`BaseRepositoryIntegrationTest` (integration/repository/*) is the **H2** lane despite the "Integration" name
(`@ActiveProfiles("integration")`). Measured on SBDEV-3805 (2026-10-16):

- A repository IT pinning `ORDER BY l.createdAt ASC, l.id ASC` stayed GREEN with `, l.id ASC` removed, even
  with 10 tied rows and the lower half rewritten (UPDATE) to move them in the heap — H2 returns ties in key order.
  Moved to `BasePostgresIntegrationTest` and the same mutant went red immediately.
- H2 enforces none of the FKs the Postgres lane does: `location.client_id` (only client **0** is seeded),
  `customerorder_cancellation_log.customerorder_id` / `customerorder_position_id`, `itemdata` → location, and
  `unitload.storagelocation_id` is NOT NULL on Postgres. Use `PgLaneFixtures` (batch → order → itemdata → position).

**Why:** a test of SQL semantics (ordering, ties, joins, constraints) on H2 can pass for a reason production
never has. **How to apply:** anything asserting query order or a join/FK shape goes on the Postgres lane; then
mutation-check it there. Related: [[a-test-can-pass-for-the-wrong-reason-vary-the-fixture]],
[[derived-finder-row-order-is-heap-order-update-moves-it]], [[wms2-pg-it-lane-has-no-tenant-pool]].
