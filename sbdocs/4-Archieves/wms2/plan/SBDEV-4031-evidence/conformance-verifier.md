---
lane: verifier (Phase 3a conformance), opus
head: 85daa64b (base 8507785d)
verdict: PASS (0 blockers)
saved_by: main session, summary of the lane's reply
---
# Conformance: PASS

**Fresh runs (verifier):**
- `mvn -o clean compile`: exit 0.
- Targeted units plus all `*ArchTest`: 834 run, 0 failures, 0 errors, 0 skipped.
- Gate and neighbour ITs: 65 run, 0 failures, 0 errors, 12 skipped. The 12 skips are 11 from the pre-existing `@Disabled` on `ReplenishorderRepositoryIntegrationTest` and 1 in `ReplenishDupConcurrencySliceIT`.

**§0 rows:**
- VERIFIED: D1, D2, D3, C0, R1/R2, R3, M1. The order F → P → L′ → O is pinned by an `InOrder` unit test.
- PARTIAL: F2. Only the javadoc was fixed; `refillFixedLocations` was not deleted. Main session decision: drop the deletion from 4031. Deleting it would remove an existing test's only assertion. It is unrelated to the race; follow-up is T0.

**§8.2 ACs:**
- VERIFIED: all of them, plus the A1 stale-hint unit test.
- AC-10c: its plan mutation (r1 lock order) is NOT killed by AC-10c itself (I14 survives). AC-10c-bis kills it with 40P01 (I14b).

**Deviations, all ACCEPTABLE:**
- `move` uses `findById().orElse(null)`. `collectTree(null)` returns an empty list, and there is no new lock upgrade.
- The A1 lock lives in `recalculateOrder`.
- `probeFalse_neverReadsFlag` now asserts `times(1).lockById(2L)` (previously `never`).
- `handlesRecalculateWhenAssignedLocationNotFound` was rewritten. It keeps its `never().save` assertion.
- The R3 finder retirement removes an exported SDR search. 0 callers were found in 4 client repos; positive control passed.
- AC-10c-bis was added.

**Not re-run by the verifier:**
- the mutation table (the implementer's evidence);
- the full `clean verify`. Re-run it at the final HEAD before push.
