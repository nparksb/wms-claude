---
name: outbox-lane-claim-it-order-flaky
description: "OutboxLaneClaimIT reds in a full `mvn verify` but passes 6/6 alone — order/shared-state flake, not your diff"
metadata:
  node_type: memory
  type: project
  originSessionId: a8c54c46-3f2f-49ad-b2a3-5beb7cdf5558
  modified: 2026-09-30T08:25:25.950Z
---

2026-09-30 (SBDEV-3551): full `clean verify` on a branch touching only JPQL keyword queries went red on
`OutboxLaneClaimIT.defaultLaneClaimsOnlyItsOwnRows` + `perOrderClubFallbackIsStillSeparated`
("could not find the following elements"); the adjacent `origin/develop` baseline run was green on it,
and the class passed 6/6 run alone. Shape = committed rows from other ITs in the shared reusable
container (see [[wms2-repository-tests-commit-they-do-not-roll-back]], [[wms2-concurrency-it-fixture-traps]]).

Same run: `CancellationReversalParcelSourceIntegrationTest.aReversalOutOfAParcelIsRefusedAndLeavesTheLockAt100`
and `SequenceTransactionServiceConcurrencyIT.concurrent50Threads100CallsEach...` were red on BOTH branch
and develop — pre-existing on develop at daf64d41.

**Why:** a branch-only red from this class looks like a regression and is not.
**How to apply:** rerun `-Dit.test=OutboxLaneClaimIT` alone before debugging; if green alone, report it as a
flake, and compare full-suite failures against a baseline run adjacent in time
([[wms2-test-suite-baseline-and-h2-verdict]]).
