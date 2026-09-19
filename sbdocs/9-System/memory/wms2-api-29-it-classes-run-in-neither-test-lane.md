---
name: wms2-api-29-it-classes-run-in-neither-test-lane
description: "CORRECTED 2026-09-13 — wms2-api *IT.java DOES run in the failsafe lane since SBDEV-3239 (2026-09-06); the old 'runs in neither lane' claim is obsolete"
metadata:
  node_type: memory
  type: project
---

**This memory used to say 28 `*IT` classes ran in neither test lane. That is no longer true.**
`pom.xml`'s failsafe `<includes>` now carries `**/*IntegrationTest.java` and `**/*E2ETest.java`
plus an SBDEV-3239 comment (dated 2026-09-06) stating *"`*IT.java` is IN the lane as of 2026-09-06.
The 28 orphaned classes this file used to describe now run"* — the blockers were fixed, not
documented. The failsafe `<excludes/>` is empty (SBDEV-3258). Verified by reading `pom.xml` on
`origin/feature/wms2-outbox-club-lane` 2026-09-13.

Consequence: the 5 outbox ITs (`OutboxClaimOrderingIT`, `OutboxTerminalHoldIT`,
`OutboxClaimExplainIT`, `OutboxConcurrentEnqueueIT`, `OutboxMigrationV1124IT`) execute, and their
Testcontainers harness migrates `db/migration`, so a new column added by a migration is present.
**Adding a Testcontainers IT is therefore a cheap, available way to pin native-SQL behaviour** — do
not decline it on the belief that ITs don't run.

**The real blind spot is different and still live:** several outbox ITs *hand-copy* the claim SQL
into a `CLAIM_SQL` string constant instead of calling `OutboxMessageRepository`. `OutboxClaimOrderingIT`'s
javadoc even asserts it is "a 1:1 copy of `findAndClaimPending`". A change to the production query
therefore leaves them green while they test a query that no longer exists — which is exactly what
PR #352's `lane` predicate did. See [[green-tests-that-prove-nothing]] and
[[absence-of-a-path-is-not-absence-of-the-guarantee]].

**The drift-proof pattern**, now in the repo as `OutboxLaneClaimIT` (PR #352): do not copy the SQL into
the test. Read the `@Query` off the repository interface by reflection, rewrite `:name` to `?`, and
execute *that* — the statement under test is then by construction the one production runs. Trap in the
rewriter: skip single-quoted literals, because `reclaimStaleInFlight` contains
`to_char(NOW(), 'YYYY-MM-DD HH24:MI:SS')` and a naive `:\w+` substitution eats `:MI`/`:SS` and yields a
statement that still parses while binding the wrong values.

**How to apply:** when a native repository query changes, grep `src/test` for a copy of its SQL text,
not just for callers of the method — a signature-change compile error will not find the copies.
