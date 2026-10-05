# M-5 — WineCo UAT stockrecord rewrite timing (2026-10-05)

- **Where:** wsl-wineco-uat (wh01_om1_v2), via psql, one explicit transaction:
  `BEGIN; SET LOCAL lock_timeout='3s', statement_timeout='60s', plan_cache_mode=force_generic_plan; PREPARE <exact @Query>; EXPLAIN …; EXPLAIN (ANALYZE, BUFFERS) …; ROLLBACK`.
- **Data:** UAT matches prd. Client 146701, hot code `'WCI PC'` = **44,251 rows** (prd 44,251), stockrecord 7,393,805 rows. No scaling needed.
- **Generic plan:** BitmapAnd of `index_stockrecord_itemdata` (lower(itemdata)) and `index_stockrecord_client_id`, with a filter on exact `itemdata`. **The index is used.**
- **ANALYZE:**
  - Execution **6,389.7 ms**, under the 10 s gate: **PASS**.
  - Scan 247 ms; the remaining ~6.1 s is writing 44,251 rows plus index maintenance.
  - Buffers: hit 2,087,424 / read 21,986 / dirtied 23,747.
- **Rollback verified:** 44,251 rows still `'WCI PC'`, 0 rows `'x'`.
- **Note:** the rewrite holds row locks on those stockrecord rows only. By design (H2), the itemdata FOR UPDATE lock is taken after it, at saveAndFlush, so the ~6 s doesn't block child-FK inserts on itemdata. A concurrent rename of the same code would wait up to the 5 s lock timeout and get 109.
