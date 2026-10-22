---
name: correlated-subquery-unknown-column-binds-outer
description: "In an ad-hoc SQL probe, a subquery column that doesn't exist on its own table silently resolves to the OUTER query's column — the filter becomes always-true, no error"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 672ddb26-dbc0-4aee-8fec-2c2440be15f2
  modified: 2026-10-15T22:21:55.041Z
---

PostgreSQL resolves an unqualified column inside a subquery by searching outward. If the inner table
lacks the column but the outer one has it, the reference binds to the **outer** row. The predicate
then compares the outer value with itself (or with a constant), which is always true. You get no
error, only a wrong result.

Measured 2026-10-15 (SBDEV-3775 dev test, `dev_wh01_om1`):
`(select string_agg(type, ', ') from stockrecord where stockunit_id=31405683)`. `stockrecord` has no
`stockunit_id` column, so it bound to the outer `goodsreceiptposition g join stockunit s … g.stockunit_id`,
whose value was 31405683. Every stockrecord row matched, and psql returned **64 MB**. A smaller table
would have produced a plausible-looking wrong answer instead.

**Why:** the same class as [[a-zero-scan-needs-a-positive-control]]: the instrument fails silently in
the direction of "looks like data". Schema guesses are routine in these probes, since v2 renamed
columns (`item_nr` not `itemnr`, `fix_location_assignment` not `fixlocationassignment`).

**How to apply:**
- Alias-qualify **every** column inside a subquery in an ad-hoc probe (`sr.stockunit_id`). An unknown
  qualified column is a hard error, which is the behaviour you want.
- If a subquery returns far more than expected, suspect outer binding before suspecting the data.

Related: [[stockrecord-staging-scan-traps]], [[failed-regex-resolution-must-not-become-a-verdict]].
