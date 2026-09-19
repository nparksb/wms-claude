# SBDEV-3410 — ARCHITECT review (ralplan consensus lane)

**Lane:** architect, READ-ONLY. The plan was not edited.
**Target:** `sbdocs/1-Projects/wms2/plan/SBDEV-3410-stock-unit-record-shipper-filter-and-product-name.md` (1,386 lines, fixed snapshot)
**Evidence base read:** `SBDEV-3410-evidence/analysis-bundle.md`
**Code read at:** `wms2-api origin/develop = 29ce240db0c9edb747346e2b6fe42287afcd0b63` via `git show origin/develop:<path>` (never a local checkout)
**DB read:** read-only `EXPLAIN` / catalog queries via the MCP targets, 2026-09-18. Nothing was created, dropped or written. `SET plan_cache_mode` and `PREPARE` are session-local and were used only to obtain plan shapes.

**Verdict: SOUND-WITH-CHANGES.** The design — a Flyway view mapped as a read-only `@Entity` on SDR — is the right one, and two of its three load-bearing claims reproduce independently under my own instruments. But one load-bearing claim does not survive contact: **the measured index payoff was taken with a literal predicate while the plan specifies a three-valued `OR` predicate, and I measured that the `OR` form cannot use any `client_id` index under a generic plan.** That is a fixable defect inside the chosen design, not a reason to change the design. Seven changes are enumerated in §5.

---

## 1. What I verified independently (and with what instrument)

| # | Claim in the plan | My instrument | Result |
|---|---|---|---|
| 1 | Both joins are eliminated when no joined column is referenced | `EXPLAIN (ANALYZE, BUFFERS)` of the inline join on `dev_wh01_om1` | **CONFIRMED.** `Finalize Aggregate → Gather (Workers Planned: 4) → Partial Aggregate → Parallel Seq Scan on stockrecord sr (rows=1945359 loops=5)`. Both joins absent. 4,898 ms. |
| 2 | Negative control for #1 | same query with `ON i.item_nr = sr.itemdata` only | **CONFIRMED the instrument works.** `Parallel Hash Left Join … Hash Cond: ((sr.itemdata)::text = (i.item_nr)::text)`, rows 1,945,359→2,013,483 per worker, i.e. **9,726,795 → 10,067,415**. 9,474 ms. The plan quotes the ARW-only multiplication (+14,835); whole-table is **+340,620**. |
| 3 | The unfiltered default *data* page stays cheap over the view | `EXPLAIN (ANALYZE)` selecting `item_name`/`cl_nr`/`cl_name` with `ORDER BY created DESC LIMIT 10` | **CONFIRMED, and stronger than the plan states.** `Limit → Nested Loop Left Join → Index Scan Backward using index_stockrecord_created` + two `Memoize`d unique probes (`Index Scan using uk3l3dgof3l6mc1dl7s3lmida65`, `Index Cond: ((client_id = sr.client_id) AND ((item_nr)::text = (sr.itemdata)::text))`). **5.398 ms.** The plan never measured this exact query; it is the one the report actually issues, and it is fine. |
| 4 | `itemdata UNIQUE (client_id, item_nr)` exists | `pg_indexes` on every reachable v2 tenant | **PRESENT on 5/5 reachable DBs** — `dev_wh01_om1`, `wh01_hydra_v2` (prd), `wh01_hydra_v2` (uat), `wh01_shipitez_v2` (uat host), `wh02_shipitez_v2` (uat host), all as `CREATE UNIQUE INDEX uk3l3dgof3l6mc1dl7s3lmida65 ON public.itemdata USING btree (client_id, item_nr)`. |
| 5 | `stockrecord_view` "does not exist on any tenant" | `information_schema.views` on the same 5 | 0 on all 5 — but see finding **F5**: "any tenant" is not established. |
| 6 | Dev row counts | `count(*)` | **Reproduced exactly:** `stockrecord` 9,726,795; `itemdata` 8,808 rows / 8,721 distinct `item_nr` (= 87 shared). Heap 2,196 MB. |
| 7 | Production runs `ddl-auto=none` | `git show origin/develop:src/main/resources/application.properties` | **CONFIRMED:** `spring.jpa.hibernate.ddl-auto=none` with `#spring.jpa.hibernate.ddl-auto=validate` commented directly above. |
| 8 | The three-valued `OR` keeps index access | `plan_cache_mode = force_generic_plan` + `PREPARE`/`EXPLAIN EXECUTE` | **REFUTED.** See §2. |

---

## 2. Strongest steelman ANTITHESIS

> **The chosen design pays a permanent, per-tenant, irreversible schema object for a performance property it does not actually deliver in the plan mode the repo has already documented itself falling into — and it pays that price to preserve an SDR contract whose one real constraint (no `toFilterId` on the read path) is exactly what forces the predicate shape that breaks the performance.**

This is not a strawman. Unpack it in three moves.

**Move 1 — the index payoff is custom-plan-only, and the plan never says so.**

§3.2 justifies the migration's second statement with "the worst case becomes `Index Scan Backward`, `Index Cond: (client_id = 419803)`, **0.455 ms** — a 6,300× speed-up". That was measured with a **literal**. The predicate the plan actually specifies is §3.4's

```
AND (p.clientId = :clientId OR :clientId IS NULL OR :clientId = -1)
```

I measured both shapes on `dev_wh01_om1`. With a literal, the planner folds the two parameter-only disjuncts away and the predicate becomes an ordinary indexable qual:

```
Limit
  ->  Index Scan Backward using index_stockrecord_created on stockrecord sr
        Filter: (client_id = 419803)
```

Under `force_generic_plan` the folding cannot happen and the disjunction survives whole:

```
Limit
  ->  Index Scan Backward using index_stockrecord_created on stockrecord sr
        Filter: ((client_id = $1) OR ($1 IS NULL) OR ($1 = '-1'::integer))
```

I isolated the `OR` as the sole cause with a paired control on the count form, same generic mode, same table, same session:

| form | generic plan |
|---|---|
| `WHERE sr.client_id = $1` | `Aggregate → Index Only Scan using index_stockrecord_client_id`, **`Index Cond: (client_id = $1)`** |
| `WHERE (sr.client_id = $1 OR $1 IS NULL OR $1 = -1)` | `Finalize Aggregate → Gather → Parallel Seq Scan on stockrecord sr`, **`Filter: ((client_id = $1) OR …)`** |

A disjunction one of whose branches does not reference the table can be true for any row, so no index condition is derivable from it. `index_stockrecord_client_created` — the 276 MB object this migration exists to create — is **unreachable** in that plan mode. The filtered first page reverts to the 2,865–4,709 ms case the index was bought to avoid.

This is not a hypothetical failure mode invented by a reviewer. The repo has already written it down once, for the same reason, in `src/main/java/net/aim_ai/wms/repo/jpa/FixLocationAssignmentRepository.java`:

> "*the 5x buffer win is custom-plan-only … Reaching a generic plan is possible here: `plan_cache_mode` is `auto`, no `prepareThreshold` is configured so pgjdbc promotes to a server-side prepared statement after five executions on a connection, and `maxLifetime` keeps a connection 30 minutes. Postgres will probably keep custom plans precisely because the generic estimate is worse — but that is a bet on estimates, which move with `ANALYZE`.*"

That javadoc even names the fix it could not use and why: "*Pinning the literal 700 into the anti-joins would guarantee the index in every plan mode. It is deliberately NOT done here: it would … change the signature of an **SDR-exported** search — a contract change.*" SBDEV-3410 is in the same trap for the same structural reason, and §10.3 item 2 mentions the generic-plan hazard **only** for the `or :keyword = ''` bonus, never for the `clientId` predicate that the entire index rationale rests on.

**Move 2 — Option B does not have this problem, and its cost is over-stated.**

§9.3 / Option B (a hand-written MVC endpoint returning a DTO page) is rejected on "a larger UI diff than the whole rest of this ticket". But the store is already hand-built: `store/reports/stockUnit.js` assembles `'?page=' + (data.page - 1) + '&size=' + data.itemsPerPage + '&state=' + data.state + '&keyword=' + data.keyword + (data.sortUrl ? '&sort=' + data.sortUrl : '')` by string concatenation and reads `results._embedded.stockrecord` / `results.page.totalElements` — three touch points, not a framework. And P6 is already rewriting all three (new path, new `_embedded` key, new parameter). An MVC endpoint would let `toFilterId` run at the controller and issue a **plain equality** predicate, index-safe in both plan modes; it would be function-gatable, closing §3.5's asymmetry as a side effect; and it needs no Flyway migration for the *filter* half at all.

**Move 3 — the migration's cost is irreversible and its correctness is not self-contained.** §8's rollback is honest that `V2.2.33` "does not revert by reverting the file" and that `DROP VIEW` needs ownership. Meanwhile the view's stated **ROW-COUNT INVARIANCE** ("Neither join can multiply: client.id is a primary key, and (client_id, item_nr) is unique on itemdata") is a property of *each tenant's schema*, not of the view text. That constraint is declared only in `src/main/resources/db/migration/V2.2.00__base_v2_schema.sql` — `ADD CONSTRAINT uk3l3dgof3l6mc1dl7s3lmida65 UNIQUE (client_id, item_nr);` — the base dump, i.e. the file legacy tenants were *baselined past* rather than ran. Nothing in `V2.2.33` creates or asserts it.

### Why the antithesis, honestly assessed, is still weaker than the chosen design

**It defeats the plan's stated justification, not the plan's design.** Three reasons:

1. **The view is needed for AC-3 regardless of how the filter is implemented.** SBDEV-3417 (`b20eb9f1`) closed interface projections, and `@Formula` is positive-controlled to zero occurrences. Even Option B needs `item_name` from somewhere; a DTO endpoint could join in JPQL, but then it is re-implementing paging *and* the join, and it diverges from the six sibling reports. The view earns its keep on the product-name half independently of the filter half.
2. **Move 1 is fixable inside the chosen design for about fifteen lines** (§4 synthesis), with no change to the view, the entity, SDR, or `Page<StockrecordView>`.
3. **Move 3 is a pre-existing dependency, not one this ticket introduces.** `V2.2.07__fix_stock_history_client_id_aggregation.sql`'s own header already reasons from it: "*UNIQUE (client_id, item_nr), so grouping and joining on (itemdata, client_id) is …*". The repo already bets on that constraint in a shipped migration. SBDEV-3410 raises the stakes; it does not create the exposure.

So: the design stands. The *justification* needs one correction and the *predicate* needs one change.

---

## 3. Tensions the plan papered over

### T1 (primary) — "stay on SDR" vs "the index is the feature"

The plan states both as settled and never notices they collide.

- §10.1 Q3: "*The shipper filter is useless without this [index]*" — the index is constitutive of the feature.
- §2.1: "*There is **no MVC controller on this path** … The three-valued semantics must therefore live in the JPQL predicate.*" — staying on SDR forces the predicate into JPQL.
- §3.4: the only JPQL shape that expresses three-valued "no filter" in one method is the `OR` disjunction.
- §2 above: that disjunction is exactly the shape that cannot reach the index in a generic plan.

The plan resolves the surface conflict (where does normalisation live?) in §10.1's "Implementation refinement on Q1" — honestly and well — and then does not follow the consequence through to the measurement. §3.2's table and §10.1 Q3's "with it 0.455 ms" are both measurements of a **different predicate** from the one §3.4 specifies. The conflict is papered over by measuring the easy shape.

### T2 (secondary) — "row-count invariance is structural" vs "join elimination requires a constraint the migration neither creates nor asserts"

Both properties hang on the same external object, and the plan treats one as structural and the other as performance:

- The SQL header asserts invariance flatly: "*The view therefore has exactly the cardinality of stockrecord.*"
- §3.1 treats constraint loss as a *speed* problem: "*Replacing either `LEFT` with `INNER`, or dropping the unique constraint, defeats elimination and the default page pays the full hash join.*"

If `uk3l3dgof3l6mc1dl7s3lmida65` is ever absent **and** a duplicate `(client_id, item_nr)` pair exists, the view multiplies — a correctness failure in an audit report, not a slow one. And the way it surfaces is nastier than "duplicate rows": with `@Id private Long id` mapped to `stockrecord.id`, Hibernate deduplicates by identifier inside the persistence context, so a `Page<StockrecordView>` would come back with the **same entity instance repeated in `content`** while `page.totalElements` — from a `count(*)` that does *not* dedupe — reports the inflated figure. A page that shows a row twice and a footer that disagrees with it is far less likely to be read as "the schema lost a constraint" than an outright error would be.

The plan cannot resolve this by construction, and that is the real tension: **making the view defend itself against constraint loss (`DISTINCT ON`, a `LATERAL … LIMIT 1`) is exactly what would destroy the join elimination**, because the planner's proof of non-multiplication *is* the constraint. You cannot have both a self-contained guarantee and the elimination. The plan takes the elimination — correctly — and then narrates the guarantee as if it had taken both.

### T3 (tertiary) — "each phase independently deployable" vs no flag and two pipelines

§5 claims each phase is "independently reviewable and independently deployable in the stated order", and §5.1 prereq 2 waives a flag: "*N/A — the feature is unconditional; no `los_sysprop` row, no toggle.*"

But P2 (`wms2-api`) and P6 (`wms2-web-ui`) are a hard runtime pair across two repos with two pipelines: P6's `searchReport` targets `/stockrecordView/search/findByKeyword`, which does not exist until P2 is *deployed*, not merely merged. Prereq 4 characterises only the benign ordering — "*The export `filter` key is inert until P3, so P6-before-P3 degrades to 'filter ignored on export', not an error*" — and never characterises P6-before-P2, which is not a degradation but a **blank report** (404 on every page load). Against the standing repo fact that a `:develop` tag race can deploy an *older* image than the merge order implies, "merge P2 before P6" is not the same guarantee as "P2 is running before P6 is running".

The same coupling inverts the rollback. §8 says "*the UI (P6) is the revert that restores today's behaviour*" — true. What it does not say is that the converse is unavailable: **once P6 is live, P2 cannot be reverted alone**, because reverting it 404s the report. There is no flag to fall back on, by prereq 2's own decision.

---

## 4. SYNTHESIS — what resolves each tension while keeping the design

### S1 (resolves T1) — split the search method; keep everything else

Replace the single three-valued method with two, both on the same repository, same entity, same view, same `Page<StockrecordView>`:

```java
@RestResource(path = "findByKeyword", rel = "findByKeyword")
@Query("SELECT p FROM StockrecordView p WHERE (CONCAT(...) LIKE LOWER(concat('%', :keyword,'%')) or :keyword = '')")
Page<StockrecordView> findByKeyword(@Param("keyword") String keyword, Pageable p);

@RestResource(path = "findByKeywordAndClient", rel = "findByKeywordAndClient")
@Query("SELECT p FROM StockrecordView p WHERE (CONCAT(...) LIKE LOWER(concat('%', :keyword,'%')) or :keyword = '') AND p.clientId = :clientId")
Page<StockrecordView> findByKeywordAndClient(@Param("keyword") String keyword, @Param("clientId") Long clientId, Pageable p);
```

`p.clientId = :clientId` is a plain equality — I measured it holding `Index Cond: (client_id = $1)` under `force_generic_plan`, so the index payoff survives in **both** plan modes. The store already branches on the filter (§3.9 specifies `if (data.clientId != null) { … }`); it selects the path in the same `if`. Cost: one extra method, one extra `if` branch, one extra IT case. It removes the only place the design's performance was contingent on a plan-mode bet.

Apply the same shape to the export (P3): `ReportService` picks between `findByOffsetAndLimit` and a `findByClientOffsetAndLimit`, rather than embedding `CAST(:clientId AS bigint) = -1 OR …` — which is the identical un-indexable disjunction in native SQL, on a path that pulls thousands of rows rather than ten.

If Nam prefers to keep one route, the minimum acceptable alternative is to **keep the `OR` and state the bet explicitly**, in the `FixLocationAssignmentRepository` javadoc's form: name `plan_cache_mode=auto`, no `prepareThreshold`, promotion after five executions per connection, and record that the 0.455 ms figure is custom-plan-only. Do not ship the current text, which presents a custom-plan number as the predicate's cost.

### S2 (resolves T2) — make `V2.2.33` assert the constraint it depends on

Add a third statement that converts a silent correctness cliff into a loud migration failure:

```sql
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.itemdata'::regclass AND contype = 'u'
      AND conkey = (SELECT array_agg(attnum ORDER BY attnum) FROM pg_attribute
                    WHERE attrelid = 'public.itemdata'::regclass AND attname IN ('client_id','item_nr'))
  ) THEN
    RAISE EXCEPTION 'stockrecord_view requires UNIQUE(client_id, item_nr) on itemdata; without it the view multiplies rows and join elimination is lost';
  END IF;
END $$;
```

(Match against the *column set*, not the generated name `uk3l3dgof3l6mc1dl7s3lmida65` — a tenant rebuilt by a different Hibernate run will have a different generated name, and a name-match would then fail a tenant that is actually correct.) Two consequences worth stating in the header: the check makes the migration fail loudly on a tenant that lacks it (which is what you want — a failed tenant migration does not abort the boot, so the operator check in prereq 8 still has to look), and it documents the dependency at the only place a future reader of the view will be standing.

Then add the constraint to prereq 8's per-tenant post-deploy check, which today verifies only the view and the index.

And correct §3.3 rule 1: `sr.id` is a safe `@Id` **conditional on the same constraint**, and the failure mode if it is absent is a deduplicated `content` against an undeduplicated `totalElements`, not visible duplicates.

### S3 (resolves T3) — sequence P6 on a *deployed* SHA, and fix the revert order

Three sentences of plan text, no code:

1. Prereq 4 gains the missing row: **P6 before P2 is a blank report (404 on every page load), not a degradation.**
2. Rollout step 5's gate becomes: confirm `/api/public/version` on the target environment reports a SHA that contains P2 — the repo's own documented way to know what is actually running — before merging P6. "Merged" is not "deployed", and the `:develop` tag race can deploy an older image.
3. §8 gains the revert order: **P6 reverts first, always.** P2 cannot be reverted while P6 is live.

---

## 5. Findings, graded against the brief's load-bearing list

### F1 — The index payoff is plan-mode contingent · **HIGH** · §3.2, §3.4, §10.1 Q3
Measured above. The stated 0.455 ms belongs to a predicate the plan does not specify. Fix: **S1**.

### F2 — Join-elimination protection is prose where it needs to be an assertion · **HIGH** · §3.1, §5.1 prereq 8
The plan protects the invariant with (a) an SQL header paragraph, (b) a Testcontainers `viewMultipliesZeroRows` IT, and (c) a mutation check. (b) and (c) run against a schema **built by `db/migration`**, where `V2.2.00` did create the constraint — so they prove the property on the migration-built schema and are structurally blind to a tenant whose schema was baselined past `V2.2.00`. No per-tenant instrument exists. Fix: **S2**.

### F3 — A drifted view has no production-side detector at all · **MEDIUM** · §3.1 header, §7.5 row 4
The brief asks whether Hibernate `validate` catches a drifted view. **It never runs in production:** `src/main/resources/application.properties` — `spring.jpa.hibernate.ddl-auto=none`. The only lane that validates is the Testcontainers profile, and it says so itself: `src/test/resources/application-postgres-integration.properties` — "*ddl-auto: `validate` (SBDEV-3285). This DIVERGES from production, which is `none`*". Even there, `validate` checks only **mapped** column existence and type, ignores extra columns and nullability, and reports the **first** mismatch and stops. So: a view redefined with a different shape on a tenant is caught by nothing at runtime; a report column silently becomes wrong or 500s. The plan states this correctly for a *missing* view ("NO STARTUP SAFETY NET … boots green and then throws 42P01") but not for a *drifted* one. Add one sentence to the header; the `CREATE OR REPLACE`-can-only-append note is already there and is the right neighbour for it.

### F4 — `SDR_WRITE_WITHDRAWN` is load-bearing, not "parity" · **MEDIUM** · §0.1 row 6, §3.5, §7.5 row 5
§3.5 says "*`SDR_WRITE_WITHDRAWN` — add for parity.*" It is not parity; it is the only thing that closes a write route. `src/main/java/net/aim_ai/wms/repo/cinterface/ReadOnlyPagingAndSortingRepository.java` suppresses exactly two methods — `save` and `saveAll` — and extends `CrudRepository<T, ID>`, so `deleteById` / `delete` / `deleteAll` remain exported. Without the withdrawal, SDR routes `DELETE /api/stockrecordView/{id}` to a handler that would issue a delete against a **view** — an unruled, un-gated route whose best outcome is a 500. The precedent supports this reading: `ViewWarehouseLocationReport` (another view-backed entity) is already in the list. Re-label the item as required, so a later reviewer cannot trim it as cosmetic.

### F5 — "does not exist on any tenant" is not established, and I found why · **MEDIUM** · §5.1 prereq 1
All three PRD tenant MCP aliases resolve to the **same database**: `nywh-hydra-prd`, `nywh-shipitez-prd` and `c1wh-shipitez-prd` each return `current_database() = wh01_hydra_v2`, `inet_server_addr() = 172.18.0.3`. Meanwhile `landlord-prd` lists three active tenant datasources — `hydra/nywh → wh01_hydra_v2`, `shipitez/c1wh → wh01_shipitez_v2`, `shipitez/nywh → wh02_shipitez_v2`. So **any "checked on every tenant" claim made through these aliases measured hydra three times.** The two ShipItEZ *prd* databases are unreachable from this session. Restate prereq 1 as "verified on the tenants reachable from the MCP set, which excludes both ShipItEZ prd databases" and make the operator re-derive it with real prd credentials before P1 merges. (This is an instrument defect, not a plan defect — but the plan inherits the false completeness.)

### F6 — The index-build stall is over-stated for every tenant I could measure, and unmeasured exactly where it matters · **MEDIUM** · §3.2, §7.6 row 8
The brief asks across how many tenants and in what order. Measured 2026-09-18:

| DB (via MCP alias) | `stockrecord` rows | heap |
|---|---|---|
| `dev_wh01_om1` (`wms2-wineco-dev`) | 9,726,795 | 2,196 MB |
| `wh01_shipitez_v2` (`c1wh-shipitez-uat`, host 10.0.0.6) | 1,675,111 | — |
| `wh01_hydra_v2` (`nywh-hydra-uat`, host 10.0.0.6) | 101,758 | — |
| `wh02_shipitez_v2` (`nywh-shipitez-uat`, host 10.0.0.6) | 28,196 | 6,656 kB |
| **`wh01_hydra_v2` (prd, host 172.18.0.3)** | **3,373** | **728 kB** |

The accepted cost — "~6 s `SHARE` lock … 276 MB" — is the **dev** figure, and dev is ~2,884× the only PRD tenant I can reach. On hydra prd the build is milliseconds. This does not change the decision (Q3 stands, and the index is right), but the "Accepted cost (Nam, 2026-09-18)" line should carry the per-tenant scale, because the thing actually accepted is a stall on the two **unmeasured ShipItEZ prd** databases, not on hydra. Add the table; delete the implication that ~6 s is what production sees.

Two related facts worth recording, both favourable: hydra prd is at `flyway_schema_history` **33 rows applied, `2.2.32` present, 0 failed**; and `stockrecord`'s owner there is `wh01_hydra_v2_app`, which **is** `current_user` — so the ownership-drift hazard the plan cites from the `V2.2.07` freeze is discharged on that tenant today.

### F7 — The count query is missing from the performance story · **MEDIUM** · §3.2, §7.7
SDR issues a `count` on every `Page`. §3.2's table reports only data-query times. Measured on `dev_wh01_om1`, today, for ARW:

```
Finalize Aggregate (actual time=559.441..601.499)
  ->  Parallel Index Only Scan using index_stockrecord_client_id on stockrecord sr
        Index Cond: (client_id = 60500)
        Heap Fetches: 873021
Execution Time: 601.949 ms
```

So a filtered page's user-perceived latency is the data query **plus ~600 ms of counting**, and the composite index does not remove that — it scans the same 873,021 entries from a wider index, and `Heap Fetches: 873021` says the visibility map is cold, so the count is heap-bound rather than index-bound. Consequence: §7.7's expected result "*first page returns in well under a second*" is not established by anything in the plan and is probably not true for a large shipper. Either restate it ("sub-second data query; total page latency dominated by the SDR count, measured ~0.6 s for the largest shipper on dev") or add the count to the §3.2 table.

### F8 — "preserves that asymmetry exactly" is false in payload terms · **MEDIUM** · §3.5, §6
The brief asks whether the deliberate no-`SdrFunctionRules`-entry is defensible. Mostly yes — but the plan's justification overclaims. "*Adding `StockrecordView` with no rule preserves that asymmetry exactly*" is true of the **rule count** (7 before, 7 after) and false of the **data**: the existing unruled route serves `stockrecord` columns only; the new unruled route additionally serves `item_name`, `cl_nr` and `cl_name` to the same audience. Any authenticated user gains an unruled, paged, keyword-searchable join of the product catalogue and the client directory onto the audit log. That is a small widening, but it is a widening, and it lands in the same ticket that widens `allClients` under a gate — an asymmetry worth stating rather than smoothing.

Context that cuts both ways, from `src/main/java/net/aim_ai/wms/security/SdrFunctionRules.java`: "*⚠ MEASURED 2026-09-03: WMS2_SDR_READ_GUARD_MODE is OFF on both dev_wh01_om1 and hydra prd (wh01_hydra_v2)*". With the read guard OFF, even a *ruled* type is unenforced, so adding a rule today would buy nothing live — which genuinely supports deferring it. Say that, rather than "preserves the asymmetry exactly": the honest claim is *"adds no new enforcement gap, because SDR read enforcement is OFF on every tenant; it does widen the payload an unruled reader sees, and the rule belongs on the SBDEV-3222/3183 programme's ticket, not this one."* Not a blocker. Not a security regression either — but not a no-op.

### F9 — Phase-boundary and revert-order gaps · **LOW-MEDIUM** · §5.1 prereq 4, §8
Per T3. Three sentences, **S3**.

### F10 — `@Id` safety should carry its condition · **LOW** · §3.3 rule 1
The argument is right and the reasoning against copying `StockView`'s `row_number() OVER ()` is excellent. Add one clause: `sr.id` is unique through the view *because* neither join multiplies, which is the constraint in **F2** — and if it is ever absent the symptom is a deduplicated `content` list against an inflated `totalElements`, not a visible duplicate.

---

## 6. What the plan gets right, and should not be talked out of

Stated so a later reviewer does not "fix" these.

- **The pair join key.** Independently confirmed: `item_nr` alone multiplies 9,726,795 → 10,067,415 on dev. The plan's insistence on `(client_id, item_nr)` is correct and the SQL header's explanation is the right level of detail for the next reader.
- **Both joins `LEFT`.** The reasoning — "*0 of 9,726,795 rows fail to resolve … so an INNER JOIN would look correct in every test; that is precisely why it must not be used*" — is exactly the right inference from a zero that agrees with the comfortable conclusion.
- **Filtering on `clientId` rather than `cl_nr` (Q1).** Independently supported: the `cl_nr` form puts the predicate on a joined column, which both breaks elimination and destroys selectivity propagation. Keep it.
- **Not widening the keyword `CONCAT`, and `sortable: false` on SKU Name.** Both defend the elimination that my §1 row 1 confirms is real. §3.10's admission that `sortable: false` is "policy with no technical enforcement" is the honest framing.
- **Not extending `AbstractBaseEntity`, explicit `@Column` on every camelCase field, and `everyMappedColumnResolves` as the instrument.** Correct, and the instrument choice matters given F3: the IT profile's `validate` is the only detector that exists.
- **`exposeIdsFor`.** Genuinely mandatory, and the reasoning traced through to `/stockRecordDetailsById/undefined` is the kind of consequence chain that usually gets found in QA instead.
- **The `(String) reqMap.get("filter")` `ClassCastException` trap** and its diagnosis as "a 200 with an error body the UI writes to disk as an `.xlsx`". That is a real, non-obvious defect caught before it shipped.
- **§7.10's recommendation not to ship a verify script.** Correct, and consistent with the standing repo position.

---

## 7. Verdict

**SOUND-WITH-CHANGES.**

The design decision the user fixed — `stockrecord_view` in `V2.2.33`, `@Entity StockrecordView`, endpoint stays on SDR returning `Page<StockrecordView>` — is correct, and the plan implements it with unusual care. The alternatives are properly closed: Option D by a commit, Option C by a positive-controlled zero, Option B on cost (over-stated, but the conclusion holds because the view is needed for AC-3 regardless). I found nothing that argues for changing the design.

Changes required before this plan is executed:

1. **S1 / F1 — split `findByKeyword` into unfiltered and filtered methods** so the `clientId` predicate is a plain equality. Do the same on the native export predicate. If the `OR` is kept instead, the plan must state that the 0.455 ms figure is custom-plan-only and name the promotion path, in the form `FixLocationAssignmentRepository`'s javadoc already uses.
2. **S2 / F2 — add the `UNIQUE (client_id, item_nr)` assertion as a third statement in `V2.2.33`** (matched on the column set, not the generated constraint name), and add it to the prereq-8 per-tenant post-deploy check.
3. **F3 — one sentence in the SQL header:** production runs `ddl-auto=none`, so a *drifted* view has no runtime detector; the Testcontainers `validate` profile is the only one, and it sees mapped columns' existence and type only, first mismatch only.
4. **F4 — re-label the `SDR_WRITE_WITHDRAWN` entry from "parity" to required**, citing that `ReadOnlyPagingAndSortingRepository` suppresses only `save`/`saveAll` and leaves `CrudRepository`'s delete verbs exported.
5. **F5 / F6 — restate prereq 1's tenant-coverage claim** to name the tenants actually reachable and exclude both ShipItEZ prd databases; add the measured per-tenant `stockrecord` sizes beside the accepted index-build cost.
6. **F7 — add the SDR count query to §3.2's table** and correct §7.7's "well under a second" expectation.
7. **S3 / F9 — prereq 4 gains the P6-before-P2 row (blank report, not degradation); rollout step 5 gates on a deployed SHA from `/api/public/version`; §8 states the revert order P6-first.**

Recommended but not blocking: **F8** — replace "preserves that asymmetry exactly" with the accurate claim (no new enforcement gap because the read guard is OFF on every tenant; a payload widening that belongs on the SDR-rules programme's ticket); **F10** — one clause on `@Id`'s condition.

---

### Method and blind spots for every completeness word used above

- "**All three PRD tenant MCP aliases**" — derived by running `SELECT current_database(), inet_server_addr()` against each of `nywh-hydra-prd`, `nywh-shipitez-prd`, `c1wh-shipitez-prd`. Blind spot: an alias could route differently for a different query; I did not test that, and I could not test the two ShipItEZ prd DBs at all.
- "**Present on 5/5 reachable DBs**" (the itemdata unique index) — `pg_indexes` filtered on `tablename='itemdata'` with `indexdef ILIKE '%UNIQUE%' AND '%client_id%' AND '%item_nr%'`. Blind spot: this is the five DBs the MCP set reaches, not the tenant population; a constraint present today can be dropped tomorrow, which is the whole point of F2.
- "**The `OR` is the sole cause**" — isolated by a paired `force_generic_plan` test on the same table in the same session, `= $1` against the three-valued disjunction, count form (no `ORDER BY`/`LIMIT` to confound the choice). Blind spot: `force_generic_plan` proves the plan *shape* under a generic plan; it does not prove the app will *reach* one. `plan_cache_mode` is `auto`, which is adaptive and will often keep custom plans — the exposure is a probability, not a certainty, exactly as `FixLocationAssignmentRepository` says ("*a bet on estimates, which move with `ANALYZE`*").
- "**`validate` never runs in production**" — `git grep`-equivalent sweep of every `*.properties|*.yml|*.yaml` under `src/main/resources` and `src/test/resources` on `origin/develop` for `ddl-auto`, which returned four files; only `src/main/resources/application.properties` is a main-lane file and it says `none`. Blind spot: an env-var or `SPRING_*` override at deploy time would not appear in the repo, and I did not read a running container's environment.
- "**`ReadOnlyPagingAndSortingRepository` suppresses exactly two methods**" — read the whole file (21 non-comment lines) at `origin/develop`. No blind spot at this size.
- Row counts and plans: single runs on a shared box, `EXPLAIN (ANALYZE)` where timings are quoted. Absolute milliseconds will not port to another tenant; the plan *shapes* (elimination present/absent, `Index Cond` vs `Filter`) are structural and will.
