# SBDEV-3153 — independent code review

- **Reviewer lane:** independent review agent, read-only (no builds, no writes to the worktree, no git state changes).
- **Date:** 2026-09-01
- **Subject:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3153`, branch `SBDEV-3153-refill-sargable-not-exists`, diffed against `origin/develop`.
- **Files reviewed:**
  - `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3153/src/main/java/net/aim_ai/wms/repo/jpa/FixLocationAssignmentRepository.java` (modified)
  - `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3153/src/test/java/net/aim_ai/wms/integration/repository/RefillFixedLocationPredicateIntegrationTest.java` (new, 498 lines)
- **Instruments used:** `git diff` / `git show`, a whitespace-normalising word-level differ over the extracted string literals, an AST-free `@Query`-block scanner over all of `src/main`, `javap -v` on the already-compiled `target/classes` artefact, and read-only SQL + `EXPLAIN (ANALYZE, BUFFERS)` against `dev_wh01_om1` (PostgreSQL 16.10, `plan_cache_mode = auto`).

**Verdict: no correctness regression. The rewrite is exactly equivalent and I could not construct a counterexample.** Two High findings, both about claims the change asserts rather than about the code it ships: the headline performance numbers are reproducible only under a *custom* plan and the javadoc states them unconditionally (H2), and the "verified on live data" equivalence evidence does not reproduce against the production predicate (H1). One Medium is a real mutation gap that would let a catastrophic mutant through both new tests (M1).

---

## Summary table

| # | Severity | Where | One line |
|---|---|---|---|
| H1 | High | `FixLocationAssignmentRepository.java` javadoc + test javadoc | "Verified on live data: 528 rows from either form" does not reproduce against the shipped predicate; the live check exercised only one of the two halves |
| H2 | High | `FixLocationAssignmentRepository.java` javadoc | `idx_replenishorder_active_item_dest` is a **partial** index; `state < :param` cannot use it under a generic plan, and the 28,130-buffer / 59.2 ms figure is custom-plan-only |
| M1 | Medium | `RefillFixedLocationPredicateIntegrationTest.seedFixture` | No fixture order above `state = 700`, so the `<` → `<>` mutant survives AC1 **and** AC2 — and it would halt replenishment on 99.8% of dev's `replenishorder` rows |
| M2 | Medium | javadoc ×2 + AC1 assertion message | "Postgres cannot drive an index from either side of a disjunction" is false — measured `BitmapOr` over both indexes. Wrong mechanism, in `src/main` |
| L1 | Low | test javadoc `seedFixture` | Both partial unique indexes misdescribed; the fixture is safe for a different reason than stated |
| L2 | Low | `executableSql` | Fail-closed regex `":[A-Za-z]"` false-positives on a `::cast`, producing a red that names the wrong cause |
| L3 | Low | `executableSql` | Unbounded substring `.replace(":replenishOrderStatus", …)` would corrupt a future prefix-sharing parameter, undetected |
| L4 | Low | `runQuery` | `excludeLanes = true` is never exercised; the `? "TRUE"` branch is dead although production passes `true` behind a sysprop |
| L5 | Low | `FixLocationAssignmentRepository.java` javadoc | Caller enumeration omits `ReplenishOrderJobService:216`, a second `getRefillFixedLocations` caller |
| L6 | Low | AC3 | Now near-tautological by construction; a two-line structural assertion would guard re-inlining directly |
| L7 | Low (informational, pre-existing) | `ItemdataRepository`, `TenantDynamicRoutingDataSource` | Same drift shape elsewhere; three MySQL-only Hikari properties set on a PostgreSQL pool |

---

## Category 1 — Semantic equivalence: **nothing found. The claim holds.**

Asked for a counterexample across NULL `requestedlocation_id`, NULL `itemdata_id`, zero open orders and the `DISTINCT` interaction. There is none, and the reasoning in the javadoc is correct as far as it goes. Restating it so the check is auditable:

`EXISTS` is TRUE iff at least one subquery row's predicate evaluates to **TRUE**; UNKNOWN rows are discarded exactly like FALSE rows, and `EXISTS` itself is never NULL. So with `C ≡ ro.state < :replenishOrderStatus`, `A ≡ ro.requestedlocation_id = fla.assignedlocation_id`, `B ≡ ro.itemdata_id = itemdata.id`:

```
EXISTS(C ∧ (A ∨ B))
  ⟺ ∃r : (C_r ∧ (A_r ∨ B_r)) = TRUE
  ⟺ ∃r : (C_r = TRUE ∧ (A_r = TRUE ∨ B_r = TRUE))      -- def. of ∧ / ∨ in K3
  ⟺ ∃r : (C_r ∧ A_r) = TRUE   ∨   ∃r : (C_r ∧ B_r) = TRUE
  ⟺ EXISTS(C ∧ A) ∨ EXISTS(C ∧ B)

∴ NOT EXISTS(C ∧ (A ∨ B)) ⟺ ¬EXISTS(C ∧ A) ∧ ¬EXISTS(C ∧ B)
```

The step that would break under two-valued reasoning is the second, and it is exactly the step three-valued logic still licenses, because "= TRUE" is a total test. Consequences, each of which I checked separately:

- **NULL `ro.requestedlocation_id`** → `A_r` is UNKNOWN → the row contributes to neither side. Identical.
- **NULL `ro.itemdata_id`** → same for `B_r`. (`replenishorder.itemdata_id` is in fact NOT NULL on dev, so this is vacuous in practice, but it is safe regardless.)
- **NULL `ro.state`** → `C_r` UNKNOWN → row discarded by both forms.
- **Zero open orders** → both `EXISTS` are FALSE, both `NOT EXISTS` TRUE. Identical.
- **`DISTINCT` interaction** → none. The clause lives in the outer `WHERE`; splitting one conjunct into two conjuncts is row-filtering only and cannot change multiplicity, so `DISTINCT` dedups the same bag. There is no `ORDER BY` in either query before or after, so no new nondeterminism is introduced either.

Empirical corroboration, run by me on `dev_wh01_om1` over 977 candidate rows (see H1 for why I had to reduce the query to get a non-empty comparison):

```
base_rows = 977, or_rows = 528, split_rows = 528, only_in_or = 0, only_in_split = 0
```

**No finding in this category.**

---

## Category 2 — Interface constant vs Spring Data / SDR: **nothing found. Verified in bytecode.**

`String REFILL_ELIGIBILITY_FROM_WHERE = …` on an interface is implicitly `public static final`, and its initialiser is a concatenation of string literals only — so under JLS §4.12.4 it is a *constant variable* and the concatenation in `@Query(value = " SELECT DISTINCT fla.* " + REFILL_ELIGIBILITY_FROM_WHERE, …)` is a constant expression, legal in an annotation.

I did not stop at the JLS argument. `target/classes/…/FixLocationAssignmentRepository.class` had already been compiled from the new source (mtime 08:43) by the concurrent build, so I read it:

```
public static final java.lang.String REFILL_ELIGIBILITY_FROM_WHERE;
  ConstantValue: String  FROM fix_location_assignment fla  INNER JOIN unitload …

RuntimeVisibleAnnotations:
  value=" SELECT DISTINCT fla.*  FROM fix_location_assignment fla  INNER JOIN … "
  value=" SELECT DISTINCT fla.id  FROM fix_location_assignment fla  INNER JOIN … "
```

The `ConstantValue` attribute confirms it is a genuine compile-time constant, and both `@Query` annotation entries carry the **fully inlined literal** — Spring Data reads a plain string, with no field access and no runtime concatenation. Nothing about the annotation processing path changed.

On the specific SDR worries:

- **Query-method derivation / search-resource export.** `RepositoryMetadata` and SDR's `SearchResourceMappings` enumerate *methods* (`ReflectionUtils.doWithMethods`). A field is never a candidate, so the constant cannot be mistaken for a derived query, and `@RestResource(path="getRefillFixedLocations")` continues to export exactly the one method it annotates.
- **HAL output / projection discovery.** SDR serialises entity and projection types; projections are discovered from `@Projection`-annotated interfaces under the configured scan packages. A `String` field on a repository interface participates in neither. No change to `_links`, `_embedded`, or the projection registry.
- **`:replenishOrderStatus` now appears twice in one native query.** This was the runtime risk I most expected to find, and it is a non-issue here — not by reasoning but by overwhelming in-repo precedent. A scanner over every `@Query` in `src/main/java/net/aim_ai/wms/repo/` finds **63 annotations that already repeat a named parameter, 45 of them `nativeQuery = true`**, including several in this same subsystem: `ReplenishorderRepository:348` repeats `:customerOrderPriority` four times, `StockunitRepository:224` repeats `:notLocked` four times, `OrderMonitorViewRepository:38` repeats `:text` eleven times, and — structurally closest — `ItemdataRepository:86` already repeats `:excludeLanes` and `:replenishOrderFinished` twice each in a query from the same replenishment flow. All are in production. Hibernate binds a named parameter to every occurrence from a single `setParameter` call, and Spring Data's `ParameterBindingParser` dedupes by name.
- **Nothing else reads the constant.** `grep REFILL_ELIGIBILITY_FROM_WHERE` returns only the three sites in this one file. Keeping it in the same interface — rather than extracting a `FixLocationAssignmentQueries` holder class — is the *safer* choice, and worth saying out loud so nobody "improves" it later: a constant referenced across class boundaries is inlined at the reference site, so an incremental rebuild of the holder alone would leave a stale SQL literal baked into the repository's class file. Same-file keeps that impossible. A Java interface cannot have a private field, so `public` is not a choice the author made.
- **ArchUnit / structural tests.** The only field-scanning rule in the suite is `LoggerAttributionUnitTest:122`, which filters on `Logger.class.isAssignableFrom(field.getType())` and skips a `String`. No rule constrains members of `repo.jpa`.

**No finding in this category.**

---

## Category 3 — SQL text fidelity: **nothing found. Only the anti-join split moved.**

I extracted the concatenated string literals from both `@Query` blocks at `origin/develop` and from the new constant, normalised whitespace runs to a single space and case-folded (legitimate, since Postgres folds unquoted identifiers and there are no quoted identifiers anywhere in these queries), then ran a word-level `SequenceMatcher`.

**Result 1 — the two originals were byte-identical after normalisation.** The only reported difference was `fla.*` vs `fla.id`, i.e. the SELECT list. So hoisting is legitimate: there was no hidden semantic divergence between the twins that the hoist would have silently resolved in one direction.

**Result 2 — old → new, for *both* queries, the complete set of word-level edits is:**

```
replace: OLD '(ro.requestedlocation_id'  ->  NEW 'ro.requestedlocation_id'
replace: OLD 'fla.assignedlocation_id or'
         ->  NEW 'fla.assignedlocation_id) and not exists (select 1 from replenishorder ro
                  where ro.state < :replenishorderstatus and'
delete:  OLD ')'
```

That is precisely and only the disjunction split. No clause was dropped, no join was reordered, no predicate was weakened. The two cosmetic normalisations the author flagged are confirmed and confirmed harmless:

- `itemData.id` → `itemdata.id`: unquoted, so Postgres folds both to `itemdata`. Identical resolution, and the reference is unambiguous — the second `NOT EXISTS` subquery's `FROM` is `replenishorder ro` alone, so `itemdata` can only resolve to the outer join.
- `ON  stockunit` → `ON stockunit`: the new constant adopted the *second* original's single space. Whitespace only.

Note the new constant retains `WHERE stockunit.unitload_id = unitLoad.id` with its mixed-case `unitLoad` (both originals had it). Harmless for the same folding reason; I mention it only so nobody reads it as a new introduction.

---

## H2 (High) — the headline performance numbers are custom-plan-only, and the javadoc states them unconditionally

`FixLocationAssignmentRepository.java`, javadoc on `REFILL_ELIGIBILITY_FROM_WHERE`:

> "Split, the same query runs in **59.2 ms** on 28,130 buffers — the location half becomes a Hash Right Anti Join and the item half an Index Only Scan on `idx_replenishorder_active_item_dest`, an index that already exists (baseline `V2.2.00`, so present on every Flyway-provisioned tenant) and that the `OR` form could not use at all."

`idx_replenishorder_active_item_dest` is a **partial** index. From `V2.2.00__base_v2_schema.sql:3876`, and confirmed identical in `pg_indexes` on `dev_wh01_om1`:

```sql
CREATE UNIQUE INDEX idx_replenishorder_active_item_dest
  ON public.replenishorder USING btree (itemdata_id, destination_id) WHERE (state < 700);
```

The query's predicate is `ro.state < :replenishOrderStatus` — a **bind parameter**. Postgres uses a partial index only when it can prove the query predicate implies the index predicate (`predicate_implied_by`). It can prove `state < 700 ⇒ state < 700` when the value is known, i.e. under a **custom** plan. It cannot prove `state < $1 ⇒ state < 700` under a **generic** plan, so the index becomes unusable and the item half degrades.

I measured all four cells against `dev_wh01_om1` (1,345 active assignments, 565 open orders). Every run was fully cache-resident (`shared hit` only, zero `read`), so **buffers is the cache-independent metric** and timings are indicative:

| Form | `plan_cache_mode` | Buffers | Exec time | Item-half access path |
|---|---|---|---|---|
| OR (pre-fix) | `force_custom_plan` | 139,503 | 110.8 ms | `Index Scan using idx_replenishorder_state`; `Join Filter … Rows Removed by Join Filter: 430044`, 126,684 buffers |
| OR (pre-fix) | `force_generic_plan` | 338,961 | 379.6 ms | `BitmapOr` → `Bitmap Heap Scan`, `Heap Blocks: exact=306591`, 312,724 buffers |
| **Split (new)** | `force_custom_plan` | **28,110** | **70.3 ms** | `Index Only Scan using idx_replenishorder_active_item_dest`, 2,403 buffers |
| **Split (new)** | `force_generic_plan` | 338,404 | 257.3 ms | `Index Scan using index_replenishorder_itemdata_id` + `Filter: (state < $1)`, **313,391 buffers** |

Two things follow.

**First, the change is not a regression** — the split is better than or equal to the OR form in both plan modes. That is the important reassurance and it holds.

**Second, the entire buffer win is custom-plan-only.** Under a generic plan the split costs 338,404 buffers against the OR form's 338,961 — a 0.2% difference, i.e. buffer-neutral — and 2.4× *more* buffers than the pre-fix number quoted in the comment (139,523). Time is still 1.5× better, so it is not harmful; but a reader of that javadoc will expect a ~5× reduction in I/O and may not get one.

The custom-plan figures do reproduce faithfully, which is why I am confident this is a plan-mode issue and not a measurement error. The pre-fix run reproduced the quoted evidence almost exactly — 139,503 buffers against the claimed 139,523, `Rows Removed by Join Filter: 430044` against the claimed 430,044, and 126,684 buffers on the join filter node against the claimed 126,684. The split run reproduced 28,110 against the claimed 28,130 and the exact `Index Only Scan using idx_replenishorder_active_item_dest` node. (The 885.9 ms pre-fix timing did not reproduce — I saw 110.8 ms with identical buffers — which just means the original measurement was taken on a colder or busier server. Not a defect; noted so the ticket's timing figures are not over-trusted.)

**Does production actually reach a generic plan?** It can, and the configuration nudges toward it rather than away:

- `plan_cache_mode` is `auto` on dev (verified), the default: five custom plans, then Postgres switches to the generic plan if the generic *estimate* is not worse than the average custom estimate.
- No `prepareThreshold` is set anywhere in `src/main`, so pgjdbc's default of 5 applies and the statement becomes a server-side named prepared statement after five executions on a connection.
- `TenantDynamicRoutingDataSource.java:100-102` sets `cachePrepStmts` / `prepStmtCacheSize` / `prepStmtCacheSqlLimit` — these are **MySQL Connector/J** property names. pgjdbc ignores all three, so there is no statement-cache tuning in effect at all (see L7).
- `cfg.setMaxLifetime(1800000)` keeps a connection for 30 minutes, and the highest-frequency caller is the replenish cron, so five executions on one connection is routine.

The honest mitigation is that Postgres will *probably* keep custom plans here, precisely because the generic plan cannot use the partial index and so estimates higher. But that is a bet on planner estimates, which move with `ANALYZE`, and it is exactly the caveat the comment should carry rather than omit.

**Recommendation — do not change the SQL in this PR.** Amend the javadoc to state that the 59.2 ms / 28,130-buffer figure requires a custom plan, that the partial index's `WHERE state < 700` predicate is not provably implied by `state < :replenishOrderStatus`, and give the generic-plan numbers above so the next person sees both. For the record, both production callers pass `WmsConstants.State.FINISHED`, which is `700` at `WmsConstants.java:123` — exactly the index bound — so two stronger fixes exist and both have real costs worth weighing separately from this PR:

- Substitute the literal `700` for the parameter in the anti-joins. Guarantees the partial index in every plan mode, but leaves `:replenishOrderStatus` unused, and dropping it changes the signature of an **SDR-exported** search (`@RestResource(path="getRefillFixedLocations")`) — a contract change, not a cleanup.
- Add a redundant literal guard `AND ro.state < 700` beside the parameterised one in the item half. Also guarantees the index, but it is a semantic no-op only for callers passing ≤ 700, and the SDR export means an arbitrary caller can pass anything. I would not do this.

Either belongs on the ticket as a follow-up, not in this change.

---

## H1 (High) — the "verified on live data" equivalence evidence does not reproduce against the shipped predicate

The same javadoc, and the test's class javadoc, both assert:

> "Verified on live data as well: 528 rows from either form, zero differing in either direction."
> (test: "`or_rows = 528, split_rows = 528, only_in_or = 0, only_in_split = 0`")

Running the **complete production predicate** — including the source-availability `EXISTS` — both ways on `dev_wh01_om1` right now:

```
base_rows = 326, or_rows = 0, split_rows = 0, only_in_or = 0, only_in_split = 0
replenish_areas = 2, open_orders = 565, open_orders_null_reqloc = 0
```

**Both forms return zero rows**, so `only_in_or = 0` and `only_in_split = 0` are satisfied trivially by `0 = 0`. The `EXPLAIN ANALYZE` runs agree independently: every plan I captured ends `Unique (actual rows=0 loops=1)`, with the source `EXISTS` eliminating all 528 survivors at `Index Scan using location_area_pkey … Filter: (useforreplenish AND (entity_lock = 0)), Rows Removed by Filter: 1`.

The figure 528 *is* real, and I found where it comes from: it is the candidate count after the anti-joins but **before** the source-availability `EXISTS`, visible as the `rows=528` node feeding the top `Nested Loop Semi Join`. It reproduces exactly if you drop that `EXISTS` from the comparison:

```
base_rows = 977, or_rows = 528, split_rows = 528, only_in_or = 0, only_in_split = 0
```

So the equivalence check was run against a **reduced** query, not the one shipping. That alone would be a documentation nit. What makes it a High is the second half:

```
blocked_by_location_half = 0
blocked_by_item_half     = 449
```

**On dev, the location half of the disjunction excludes zero rows.** All 449 exclusions come from the item half. So even the reduced live comparison exercised only *one* of the two clauses the change splits — it structurally could not have detected an error in the location half. Relatedly, `open_orders_null_reqloc = 0`: dev has no open order with a NULL `requestedlocation_id`, so the NULL shape the comment reasons about is untested on live data too.

**This is a defect in the evidence, not in the code.** The equivalence holds by the proof in Category 1, which I verified independently, and the location half *and* the NULL-`requestedlocation_id` shape *are* both covered behaviourally — by AC2's `FLA_LOC_BLOCKED` quadrant and by `replenishorder(…, 3153103L, 100, itemOf(FLA_ITEM_BLOCKED), null)` in the Testcontainers fixture. The fixture is doing the work the live check is credited with.

**Recommendation.** Replace the "528 rows from either form" sentence in both javadocs with what is actually true: that the full predicate returns zero rows on dev, that a reduced form (anti-joins only, source `EXISTS` dropped) yields 528 = 528 with zero divergence over 977 candidates, and that on dev the location half blocks nothing so the live check covers only the item half — with the four-quadrant fixture named as the instrument that covers the rest. A `src/main` comment that credits live data with more than it showed is how the next person skips a check they should repeat.

---

## M1 (Medium) — the `<` → `<>` mutant survives both new tests, and it would halt replenishment

`RefillFixedLocationPredicateIntegrationTest.seedFixture` seeds four `replenishorder` rows at states `100, 100, 100, 700`. Nothing above 700. The reported mutation set covered `<` → `<=` (killed: `FLA_CLOSED_ORDER` at state 700 becomes blocked, AC2 red). It did not cover `<` → `<>` / `!=`, and that mutant is **green on both AC1 and AC2**:

- AC1 only inspects the anti-join blocks for a disjunction and for the two column names. `ro.state <> :replenishOrderStatus` contains neither an `OR` nor a missing column. Passes.
- AC2: with `<>`, the three state-100 orders still block (100 ≠ 700) and order `3153105` at state 700 still does not (700 = 700). The expected set `{FLA_CLEAN, FLA_CLOSED_ORDER}` is unchanged. Passes.

The mutant is not benign. State distribution on `dev_wh01_om1`:

```
state | count
  300 |    565
  700 |    170
  800 | 388355
```

**388,355 of 389,090 rows — 99.8% — sit at state 800**, precisely the population where `state < 700` and `state <> 700` disagree. Under the mutant every one of those closed orders becomes a blocker on its item, and `getRefillFixedLocations` would return approximately nothing: replenishment order generation stops, silently, on both the cron path and the mobile confirm path. That is the highest-consequence single-character mutation in this predicate and it is currently uncovered.

**Recommendation.** One fixture row closes it: a sixth assignment `FLA_PAST_FINISHED` with an order at state `800` matching both columns, asserted eligible. Two lines in `seedFixture` plus one constant in the expected set. It also gives the fixture a row in the state band that dominates real data, which the current five do not.

Two adjacent survivors, both **out of this change's scope** and mentioned only so the fixture's reach is not overstated: `stockunit.amount < fla.lowerbound` → `<=` survives (fixture has 5 vs 10, true either way), and `fla.active = 'true'` has no inactive-assignment row.

---

## M2 (Medium) — the stated mechanism is wrong, in three places including `src/main`

The claim appears verbatim in the repository javadoc, in the test class javadoc, and inside AC1's failure message:

> `FixLocationAssignmentRepository.java`: "Postgres cannot drive an index from either side of a disjunction, so that form degraded to a nested loop rescanning every open replenishorder once per candidate row."
> AC1: `"this replenishorder anti-join contains a disjunction, which Postgres cannot drive an index from"`

Postgres *can* drive indexes from both sides of a disjunction — that is what `BitmapOr` exists for. Measured, OR form under `force_generic_plan`:

```
->  Bitmap Heap Scan on replenishorder ro (actual rows=0 loops=977)
      Recheck Cond: ((requestedlocation_id = fla.assignedlocation_id) OR (itemdata_id = itemdata.id))
      Filter: (state < $1)
      Heap Blocks: exact=306591
      ->  BitmapOr
            ->  Bitmap Index Scan on replenishorder_requestedlocation_id
            ->  Bitmap Index Scan on index_replenishorder_itemdata_id
```

Both indexes, both sides. The two real cost drivers, which the comment should name instead:

1. The disjunction forces the whole `state` test into a post-index `Filter` / `Join Filter`, so the **partial** index `idx_replenishorder_active_item_dest` cannot be chosen — under a custom plan the OR form falls back to `Index Scan using idx_replenishorder_state` and discards `430044` rows in the join filter for 126,684 buffers.
2. An OR-correlated anti-join cannot be flattened into a hash anti-join, so it stays a per-outer-row nested loop (977 loops). The split lets each half pick its own strategy — the location half became `Hash Right Anti Join` on 157 buffers, the item half an index-only probe on 2,403.

This matters because a wrong mechanism in a `src/main` comment is load-bearing for the next optimisation: someone reading "Postgres cannot use an index across an OR" will not think to check partial-index predicate implication, which is the actual constraint here and the subject of H2.

**Recommendation.** Rewrite the mechanism sentence in all three places around the two real causes, and soften AC1's message to describe the *shape* it forbids and why it is slower, without asserting a false planner limitation.

---

## L1 (Low) — the partial unique indexes are misdescribed; the fixture is safe for a different reason

`RefillFixedLocationPredicateIntegrationTest.seedFixture` javadoc:

> "Every open order is given a distinct item to stay clear of the partial unique indexes `idx_replenishorder_active_item_dest` and `idx_replenishorder_active_item_no_dest`, both of which are unique on `itemdata_id` for `state < 700`."

Neither description is accurate. From `pg_indexes` on `dev_wh01_om1`, matching `V2.2.00__base_v2_schema.sql:3876,3883`:

```sql
CREATE UNIQUE INDEX idx_replenishorder_active_item_dest
  ON public.replenishorder USING btree (itemdata_id, destination_id) WHERE (state < 700);
CREATE UNIQUE INDEX idx_replenishorder_active_item_no_dest
  ON public.replenishorder USING btree (itemdata_id) WHERE ((state < 700) AND (destination_id IS NULL));
```

The first is a **two-column composite** and happily accepts duplicate `itemdata_id` values with distinct `destination_id`s; only the second is unique on `itemdata_id` alone, and only for `destination_id IS NULL`. Note also that both key on `destination_id`, which is a **different column** from the `requestedlocation_id` the query's location half tests.

The fixture does not collide — but for a reason the comment does not state. `replenishorder(…)` never populates `destination_id`, so every fixture order has `destination_id = NULL` and falls under `_no_dest`, which *is* unique on `itemdata_id`; the three open orders carry `ITEM_DECOY`, `itemOf(FLA_ITEM_BLOCKED)` and `itemOf(FLA_BOTH_BLOCKED)`, which are distinct, and order `3153105` at state 700 sits outside both predicates entirely. Safe.

The reason this is worth fixing rather than shrugging at: M1 asks for a sixth order, and someone acting on the comment as written would reason about the wrong index. State it as "all fixture orders leave `destination_id` NULL, so `idx_replenishorder_active_item_no_dest` applies and every open order needs a distinct `itemdata_id`."

## L2 (Low) — the fail-closed regex false-positives on a PostgreSQL cast

`executableSql`:

```java
assertThat(Pattern.compile(":[A-Za-z]").matcher(sql).find())
    .as("every named parameter of %s must be substituted before execution; …")
    .isFalse();
```

`:[A-Za-z]` matches the second colon of a `::` cast whenever a letter follows — `'0'::numeric` matches at `:n`, as does `::text`, `::timestamptz`, `::boolean`. There is no cast in this SQL today (I checked the constant), so the guard is correct as it stands. But the source-availability `EXISTS` compares `su.amount > 0` and `su.reservedamount = 0` against `numeric` columns, and one `::numeric` added there — a plausible future edit — turns this into a red whose message says "every named parameter must be substituted", pointing the reader at parameter binding when the problem is elsewhere. Use `Pattern.compile("(?<!:):[A-Za-z]")`.

## L3 (Low) — unbounded substring replacement on the parameter name

```java
String sql = productionSql(methodName)
    .replace(":replenishOrderStatus", Integer.toString(replenishOrderStatus))
    .replace(":excludeLanes", excludeLanes ? "TRUE" : "FALSE");
```

`String.replace` is a plain substring replace with no token boundary. A future parameter that has an existing one as a prefix — `:replenishOrderStatusMax`, `:excludeLanesStrict` — would be rewritten to `700Max` / `FALSEStrict`, leaving no `:` behind, so the L2 fail-closed check would not see it and the failure would surface as an opaque Postgres syntax error. Bound the replacement (`replaceAll(":replenishOrderStatus\\b", …)`), or better, assert up front that the method's `@Param` names are exactly `{replenishOrderStatus, excludeLanes}` — which also fails loudly and by name if someone adds a third parameter.

## L4 (Low) — `excludeLanes = true` is never exercised

`runQuery` hard-codes the parameters:

```java
ResultSet rs = st.executeQuery(executableSql(methodName, FINISHED, false))
```

`executableSql` is never called with `excludeLanes = true`, so the `? "TRUE"` branch is dead and the `AND (:excludeLanes = FALSE OR (lo.staginglane IS NOT TRUE AND lo.transferlane IS NOT TRUE))` predicate never runs against real Postgres in either state. Production does pass `true`: `ReplenishOrderJobService.java:213-216` reads `SYSTEM_PROPERTY_REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED_KEY` and passes the result through, and `ReplenishOrderJobServiceUnitTest:430-443` asserts that wiring at the mock boundary — so the SQL side is the untested half.

Outside this change's scope. But the fixture already builds two locations per assignment, so one extra source location with `staginglane = true` plus a second `runQuery` overload would make the whole `excludeLanes` predicate real for a handful of lines, on a fixture that is otherwise paid for.

## L5 (Low) — the caller enumeration is incomplete

The javadoc says:

> "`ReplenishGeneratorService.refillFixedLocations` drives the first, `ReplenishOrderJob:429` the second via `ReplenishOrderJobService:267`, and after PR #228 the first also runs on every single-unit-load mobile replenish confirm."

Every claim there checks out — `ReplenishGeneratorService.java:85,94`; `ReplenishOrderJob.java:429` → `ReplenishOrderJobService.java:267,270`; `MobileReplenishService.java:720` and `:1128` both call `refillFixedLocations()`. But `getRefillFixedLocations` has a **second** direct caller the sentence omits:

```java
// ReplenishOrderJobService.java:208-216
@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)
public void triggerRegularReplenishment() {
    …
    List<FixLocationAssignment> assList =
        fixLocationAssignmentRepository.getRefillFixedLocations(WmsConstants.State.FINISHED, excludeLanes);
```

The comment reads as a one-driver-per-query mapping, and it is two-and-one. This is not pedantry: `triggerRegularReplenishment` is the cron's regular-replenishment path and plausibly the highest-frequency caller in the system, which makes it the one most likely to drive a connection past pgjdbc's prepare threshold and into the generic plan of H2. Add it.

## L6 (Low) — AC3 is now near-tautological

AC3 compares the row sets of the two queries. Since both `@Query` values are now built from the same constant, they are identical apart from the SELECT list *by construction* — the bytecode confirms it — so AC3 can only fail if a SELECT-list change alters semantics, or if someone re-inlines the twins **and** the divergence happens to be visible in a five-row fixture. The javadoc is candid about this ("AC3 remains as the guard against someone re-inlining them"), but the guard it describes is weaker than the guard it could be.

A structural assertion would meet the stated goal directly and cost two lines: strip each `@Query` value up to `FROM` and assert the remainders are equal after whitespace normalisation. That fails immediately on any re-inlining that introduces *any* divergence, fixture-visible or not. Keep the behavioural AC3 alongside it; it is cheap and it exercises the SELECT lists against real Postgres.

## L7 (Low, informational — pre-existing, out of scope)

Recorded per the sibling-sweep rule; neither belongs in this PR.

- **The same drift shape exists elsewhere.** `ItemdataRepository.getIdsForItemDataWithoutFixedAssignment` carries `@Query(value = …, countQuery = …)` where the `countQuery` duplicates roughly thirty lines of the value's `FROM`/`WHERE` verbatim — exactly the two-copies-that-can-drift hazard SBDEV-3153 is closing here, and a candidate for the same treatment. (Its `replenishorder` anti-join is already one-column-per-clause and sargable, so there is no OR to fix.)
- **Three inert Hikari properties.** `TenantDynamicRoutingDataSource.java:100-102` sets `cachePrepStmts`, `prepStmtCacheSize` and `prepStmtCacheSqlLimit`. Those are MySQL Connector/J property names; pgjdbc ignores all three. So there is no statement-cache configuration in effect on any tenant pool, and pgjdbc's default `prepareThreshold = 5` governs unopposed — which is the mechanism behind H2.

---

## Category 4 — test quality: can it pass while the code is wrong, or fail while it is right?

Beyond M1 and L2–L4, I probed the specific mechanisms named in the review request.

**`replenishorderAntiJoinBlocks` (AC1's extractor) — correct, with a bounded blind spot.** The regex `NOT\s+EXISTS\s*\(` anchors on `m.end() - 1`, which is the opening paren, then counts depth to the matching close. On the shipped SQL it returns exactly the two `replenishorder` blocks. Scoping is right for the reason the javadoc gives: the legitimate `(:excludeLanes = FALSE OR …)` disjunction sits inside a bare `EXISTS`, which `NOT\s+EXISTS` does not match, and that block contains no `replenishorder` either — so it is excluded twice over. `\bOR\b` with word boundaries cannot false-positive on a column containing "or" (`ro.origin_*`, `operator_id`). If paren matching ever fails the block is simply not added, and the `isNotEmpty()` guard converts that into a red rather than a pass. Genuinely fail-closed.

The blind spot the javadoc admits (a predicate moved to a view, a `@NamedQuery`, or runtime assembly) is real and correctly described; `productionSql`'s `assertThat(q).isNotNull()` catches the `@NamedQuery` and runtime-assembly cases by name, which is the right treatment. One case it does *not* catch: a semantically wrong rewrite that avoids `OR` while still mentioning both columns — e.g. `AND fla.assignedlocation_id IN (ro.requestedlocation_id, ro.itemdata_id)` passes AC1 outright. AC2 catches it. The AC1/AC2 division of labour holds.

**`productionSql` — a good decision, worth preserving.** Looking the method up by *name* over `getMethods()` and asserting exactly one match, rather than by signature, is the right call and the javadoc's reasoning is correct: a `NoSuchMethodException` from a signature edit is a red that proves the test noticed something, not that the guarded property broke, and unattributable kills are worthless in a mutation check. Reading the SQL off the annotation rather than transcribing it is the single most important choice in the file — a transcription would keep passing after someone edited the repository, which is the precise failure mode this ticket instantiates.

**Fixture isolation across the five quadrants — verified sound.** Every assignment gets its own `itemdata`, pick-face `location`, `unitload` and `stockunit`, plus its own source `location`/`unitload`/`stockunit`, via disjoint id offsets (`+10M` … `+70M` on the assignment id). I traced each quadrant against the actual predicates:

- `FLA_LOC_BLOCKED` (3153002): the only order pointing at `fixLocationOf(3153002)` carries `ITEM_DECOY`, and no open order carries `itemOf(3153002)`. Location half alone excludes it — so dropping that half admits it. Correct, and this is the quadrant the live-data check (H1) could not cover.
- `FLA_ITEM_BLOCKED` (3153003): its order carries `itemOf(3153003)` with `requestedlocation_id = NULL`, and no open order points at `fixLocationOf(3153003)`. Item half alone excludes it — **and this is where the NULL `requestedlocation_id` shape actually gets tested**, since dev has none (H1).
- `FLA_BOTH_BLOCKED` / `FLA_CLOSED_ORDER` / `FLA_CLEAN`: as documented.
- The pick faces sit in `AREA_FIXFACE` with `useforreplenish = false`, so an assignment can never satisfy the source `EXISTS` from its own stock, and the source `stockunit` shares the item but a different `unitload`, so `WHERE stockunit.unitload_id = unitLoad.id` filters it out of the main join. Both isolations hold.
- Setting `reservedamount = 0` explicitly is a real catch, correctly commented — the column is nullable with no default and the source `EXISTS` requires `= 0`, so a NULL would silently make every source invisible and turn AC2 into a vacuous "nothing is eligible".

**Partial-index collision — no collision.** See L1: the fixture is safe, but the stated reason is wrong, and the correct reason (`destination_id` is always NULL, so `_no_dest` is the operative index) is what the sixth row of M1 needs.

**Fixture hermeticity — confirmed.** `grep -i "insert into.*fix_location_assignment" src/main/resources/db/migration/` returns nothing, so the baseline seeds no assignments and AC2's `containsExactlyInAnyOrder` cannot be polluted by migration data.

**Harness placement — correct, and it matters.** `pom.xml:662-665` lists exactly `**/*IntegrationTest.java` and `**/*E2ETest.java` in failsafe's `<includes>`, and `pom.xml:518-521` *excludes* those same two patterns from surefire. So `RefillFixedLocationPredicateIntegrationTest` runs under `mvn verify` and **not** under `mvn test`. The javadoc's SBDEV-3091 reasoning about `*IT` being dead in both lanes is accurate. Two consequences for verification hygiene:

- If the suite currently running in this worktree is `mvn test`, it did **not** execute this test, and a green result from it is not evidence about AC1–AC3. Per the pom's own note, the working single-class invocations are `mvn verify -Dit.test=<Class> -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` or `mvn test -Dtest=<Class>` (surefire overrides its own exclude for an explicit `-Dtest`), and `mvn failsafe:integration-test -Dit.test=<Class>` reports `Tests run: 0` + `BUILD SUCCESS` for any class and proves nothing.
- `postgres:16` matches the dominant convention (7 of the 9 `PostgreSQLContainer` declarations in `*IntegrationTest` classes) and matches production — dev reports `server_version = 16.10`. The container is stopped in `@AfterAll` with no `withReuse`, so no container leak.

---

## Category 5 — tenant-shape risks

- **A tenant reaching a generic plan** is the one that differs materially, and that is H2. It is a plan-mode axis rather than a data axis, so it can bite any tenant, and it will bite the busiest ones hardest — the ones the ticket targets.
- **Open orders with NULL `requestedlocation_id`.** Dev has none (`open_orders_null_reqloc = 0`). Covered by the proof and by AC2's `FLA_ITEM_BLOCKED`; not covered by the live-data evidence (H1).
- **Zero-row tenants.** Both `NOT EXISTS` are TRUE with an empty `replenishorder`; no divergence possible.
- **A tenant where the location half actually blocks.** Dev's `blocked_by_location_half = 0`, so no environment has yet exercised that half on real data. AC2 covers it; H1 documents the gap.
- **A tenant missing `idx_replenishorder_active_item_dest`.** The javadoc's hedge — "present on every Flyway-provisioned tenant" — is the right hedge, since both indexes are in the `V2.2.00` baseline. Any tenant baselined outside Flyway would lose only the H2 best case, falling back to the generic-plan row of the matrix, which is still no worse than the pre-fix OR form. Not a correctness concern, and I did not attempt a cross-tenant index inventory.
- **A tenant with orders above `state = 700`** is the norm, not the exception — 99.8% of dev's rows. That is M1.

---

## What I would change before merge

1. **M1** — add the `state > 700` fixture row. Highest value per line in the whole review: it closes a mutant that would stop replenishment generation outright.
2. **H2** — qualify the performance javadoc with the plan-mode caveat and the generic-plan numbers. Leave the SQL alone.
3. **H1** — replace the "528 rows from either form" sentence with what actually reproduces, and credit the fixture for the coverage it provides.
4. **M2** — fix the mechanism sentence in all three places.
5. **L1–L6** — all small; L2 and L3 are one-line hardening, L5 is one clause, L6 is two lines.

Nothing here blocks the approach. The rewrite is correct, the hoist is safe and verified at the bytecode level, the SQL text moved exactly as advertised, and the test reads its subject from the annotation rather than transcribing it — which is the choice that makes the whole pin durable.
