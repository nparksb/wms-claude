# SBDEV-3952 — Critic review, ralplan round 1 (2026-10-30)
Reviewer: oh-my-claudecode:critic (opus), independent lane, did not see the Architect review. Saved by the main session.
**VERDICT: ITERATE.** 2 High, 4 Medium, 4 Low.

## High
- **H1. Test 3's mutation is equivalent.** The mutation is "joined sum + GROUP BY incl. su.id". With su.id in the group, each group holds one stock unit, so every row still shows 5 and test 3 stays green. **Fix:** use a fan-out subquery mutation instead, e.g. joining `unitload ul2 ON ul2.storagelocation_id = r.destination_id JOIN stockunit su2`. That makes each row show 10, so test 3 goes red while test 2 stays green.
- **H2. TDD-gate sequencing.** If the IT calls `getStockUnitId()`, the class doesn't compile before the entity change, so every test is red for the wrong reason. The JDBC route fails differently, with BadSqlGrammar. `ReportViewListKeyUnitTest` is not red at step 2. **Fix:**
  - On the old view, first assert the symptom through the 13 old columns (row count, value 5, page 2 not empty).
  - Assert stock_unit_id distinctness after that.
  - Drop ListKey from step 2's red list.
  - Merge steps 3 and 4: step 3 alone breaks the build.

## Medium
- **M1. Seed constraint missing.** `fix_location_assignment.assignedunitload_id` is NOT NULL, UNIQUE and an FK to unitload. If that UL sits on the flowbin itself, test 4 survives the `LEFT JOIN unitload → JOIN` mutation. **Fix:** put the assigned UL on a non-flowbin location, or use the `LEFT JOIN stockunit → JOIN` mutation. Also list the other NOT NULL FKs (location `area_id`/`client_id`/`type_id`; unitload `type_id`/`labelid` UNIQUE; itemdata `handlingunit_id`; replenishorder `number` UNIQUE/`prio`/`client_id`). `PgLaneFixtures` has helpers.
- **M2. "At most one NULL-SU row per location" is a fact about today's data, not the SQL.** Two empty ULs give identical rows. A stocked UL plus an empty UL gives a phantom row that now repeats the flowbin total. **Fix:** reword, add a risk row, and either add an IT or make the key real with `ul.id AS unitload_id`.
- **M3. ACs and the File Change Summary are missing from the plan.** Copy AC1–AC6 into the plan, mapping each to its test. AC5 is enforced by PostgreSQL.
- **M4. Manual scenario 1 can pass vacuously.** Add the item-only precondition (currently 12) and abort the scenario if it reads 0.

## Low
- **L1.** Add the pre-aggregated derived-table option to the alternatives. Option B's 2,021 ms was measured on the old shape. `f.*` is not forced (`f.id` would do).
- **L2.** Relabel test 7 as a behaviour guard; the arch pin is the instrument for the ORDER BY mutation.
- **L3.** The P34 row in `proposals-register.md:56` still says "group by su.id". Update it.
- **L4.** The test 2 seed needs equal `reservedamount` too.

## Solid
- Tests 1 and 6 are red today for the right reason.
- Tests 4 and 5 are green guards.
- Test 5's states 600 and 700 can coexist under the partial unique index.
- No triggers on the seed tables.
- "No verify script" is justified.
- The checklist and §7 are filled.
- The 42501 check is concrete.
