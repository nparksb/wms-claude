---
name: sbdev-3153-refill-or-split
description: "SBDEV-3153 split the non-sargable OR in FixLocationAssignmentRepository's refill anti-join — MERGED on dev 2e9ddcfa; the ticket's own mechanism, speedup and equivalence claims were all partly wrong"
metadata:
  node_type: memory
  type: project
---

**SBDEV-3153 — MERGED `on dev` 2026-09-01, merge commit `2e9ddcfa`, PR #256.** Verified on
`origin/develop` after the merge: two `replenishorder` anti-joins, no `OR` in either. T1. Split
`NOT EXISTS (C AND (A OR B))` into two `NOT EXISTS` in `FixLocationAssignmentRepository`, and hoisted the
shared FROM/WHERE of `getRefillFixedLocations` / `getRefillFixedLocationIds` into a compile-time constant
`REFILL_ELIGIBILITY_FROM_WHERE`. The two queries were byte-identical apart from whitespace, so the constant
makes the drift the ticket asked me to *test for* impossible instead. No migration, no schema change.

**The fix is right, but three of the ticket's own claims were not** — all three written by Nam, all three
found by the review lane, and worth remembering because they are the kind of claim that gets re-quoted:

1. **"That `OR` is non-sargable: it prevents any index-driven anti-join" is FALSE.** Postgres indexes across
   an `OR` via **`BitmapOr`**, and demonstrably does under a generic plan. The real costs are that the
   disjunction pushes the `state` test into a post-index filter (which makes the *partial* index
   unselectable — see [[postgres-partial-index-unusable-with-bind-parameter]]) and that an OR-correlated
   anti-join cannot be flattened into a hash anti-join.
2. **"13× faster, 5× fewer buffers" is custom-plan-only.** Under `force_generic_plan` the two forms are
   buffer-*neutral* (338,961 vs 338,404). Split is never worse in either mode, so the change stands.
3. **"Equivalence verified on live data, not just asserted" was asserted for half of it.** The full predicate
   returns **zero rows** on dev (only 2 replenishable location areas), so the `528 = 528` figure came from a
   *reduced* query. And `blocked_by_location_half = 0` — all 449 exclusions come from the item half — so the
   live check structurally could not have caught an error in the location half.

**Also: the original 683.7 ms did not reproduce (110.8 ms) with IDENTICAL buffer counts.** On this DB
**buffers are the reproducible metric and timings are not** — quote buffers.

Docs: `wms2-replenishment-design.md` said refill eligibility triggers on `upperbound` in two places; the
query uses `lowerbound` and the upper bound is the *fill target*. Pre-existing, corrected.
