# SBDEV-3410 P1 — conformance verification lane

**Subject:** commit `bfb5b860` on `feature/SBDEV-3410-p1-stockrecord-view-migration`
**Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3410`
**Lane:** read-only. Nothing in the repo was edited, no branch or worktree created, no stash touched, no DB mutated.
**Date:** 2026-09-18
**Scope:** §5.2 **P1 only**. P2–P6 are out of scope and are not reported as gaps.

---

## Verdict

| Axis | Verdict |
|---|---|
| **Correctness of what was committed** | **PASS** — no defect found in the migration, the guard, or the test |
| **§5.2 P1 checklist completeness** | **INCOMPLETE** — 5 of 7 rows VERIFIED, 1 MISSING, 1 BLOCKED |
| **Overall** | **PASS with two open items** (§A below) — nothing here blocks the commit; both open items are recorded, not hidden |

---

## ⚠ Read this first — the worktree changed under this review

Partway through the lane, `V2.2.33__stockrecord_view.sql` and `StockrecordViewSchemaIT.java` were
**modified in the working tree by another session** (`git status` went from clean to
`M` on both; `git diff --stat bfb5b860` → `37 +++---` and `86 ++++---`). The cwd was also
changed out from under this lane. Consequences, stated so nobody reads a false red:

- **Every grade below is against the committed tree at `bfb5b860`**, which is what was asked for. Where
  the working tree has since moved, it is called out explicitly and labelled as such.
- **My full failsafe-lane run is contaminated and is NOT a verdict.** `mvn -o verify` (all ITs)
  returned `Tests run: 395, Failures: 0, Errors: 20` — 18 `FlywayValidate Validate failed` and
  **2 `FlywayMigrate Script V2.2.33__stockrecord_view.sql failed … SQL State: P0001 … stockrecord_view
  requires UNIQUE(client_id, item_nr) on itemdata`** (`ReplenishMonitorVisibilityIntegrationTest`,
  `LockOverviewViewIT`). In the *same* run, four other from-scratch `db/migration` migrates passed
  (`StockrecordViewSchemaIT` 4/4, `ReplenishmentMonitorViewSchemaIT`, `BillofladingTransferIdNotNullIT`,
  `CancellationLogPickingorderPositionIdIT`) — identical harness, identical file, opposite results, which
  is only possible if `target/classes/db/migration/` was overwritten mid-run by a concurrent build.
  **Re-run targeted afterwards, both are green:** `mvn -o verify -Dit.test='LockOverviewViewIT,ReplenishMonitorVisibilityIntegrationTest'`
  → `Tests run: 11, Failures: 0, Errors: 0`, BUILD SUCCESS. This is the documented
  *concurrent-Maven-in-one-worktree = false reds* trap. **Do not treat those 20 errors as a finding.**
- **What that leaves genuinely open:** nobody — not the implementer, not this lane — has a clean
  **full failsafe-lane** result for this migration. The committed evidence covered only
  `-Dit.test=StockrecordViewSchemaIT`. V2.2.33 mutates the schema that ~20 other ITs migrate from
  scratch, so the full lane is the instrument that answers "does this break a sibling". It should be
  re-run once the worktree is quiet, by one lane alone.

---

## A. The two open items

### A-1 — MISSING: the third mutation row has no killing test

§5.2 P1 requires three mutation checks. Two were done. The third — *"delete the `DO $$ … $$`
assertion block and confirm `StockrecordViewSchemaIT`'s new `constraintIsAsserted` case goes red —
**otherwise the third statement is prose that happens to be executable**"* — **has no test to go red**.
`StockrecordViewSchemaIT` at `bfb5b860` declares exactly four `@Test` methods:

```
view_shouldNotMultiplyRows_whenOneSkuStringIsSharedByTwoShippers
view_shouldPreserveRow_whenItsSkuResolvesToNoItemdataRow
view_shouldResolveItemName_perShipper_whenSkuStringIsShared
index_shouldExistOnClientIdAndCreated
```

There is no `constraintIsAsserted`, and the commit message's *"Tests: 4/4 green"* is consistent with
that — 4 is the count of a suite that is missing this case, not evidence it exists. §7.2 already carries
the full recipe (copy `BillofladingTransferIdNotNullIT`'s `migrateTo(url, target)` + its SQLSTATE
cause-chain walker; `migrateTo(url,"2.2.32")` → `ALTER TABLE itemdata DROP CONSTRAINT …` →
`catchThrowable(() -> migrateTo(url, null))` → **assert SQLSTATE `P0001`, not the message text**,
because Flyway's message quotes the script filename and a text match passes for any failure of that
script).

Mitigating, and worth recording because it is real evidence: during this lane an intermediate revision
of the DO block **did** fail the migration on two from-scratch `db/migration` migrates with exactly
`SQL State : P0001` and the block's own message. So the statement is demonstrably executable and
demonstrably loud — but that was an accident of a concurrent edit, not a standing regression test.
Nothing in the committed tree would notice if the block were deleted.

*(The working tree now shows a 5-test `StockrecordViewSchemaIT` — a targeted re-run reports
`Tests run: 5, Failures: 0, Errors: 0`. If that fifth test is `constraintIsAsserted`, this item closes;
it is not in `bfb5b860` and is therefore not graded here.)*

### A-2 — BLOCKED: the post-index `EXPLAIN` re-measurement is not recorded

§5.2 P1: *"After the index exists on dev, re-measure BOTH shapes under `plan_cache_mode =
force_generic_plan` … and record the plans and times back into §3.2."* Neither half is recorded: §3.2
still reads *"Still unmeasured, and P1 must close it"*. Measured on `dev_wh01_om1` 2026-09-18, the
index does not exist:

```
SELECT count(*) FROM pg_indexes
 WHERE tablename='stockrecord' AND indexname='index_stockrecord_client_created';  -- 0
SELECT max(version) FROM flyway_schema_history WHERE success;                     -- 2.2.32
```

So this row is **not closeable before the merge that builds the index** — it is sequenced wrong in the
checklist, not skipped. The export half ("the `Sort` node is gone") is already recorded as
measured-unsatisfiable-with-a-keyword and is explicitly out of scope for me. The **read-path** half
(acceptance: `Index Cond: (client_id = $1)` present) is equally unclosed and should be re-stated as a
post-merge action on the ticket rather than left as a P1 checkbox.

---

## B. §5.2 P1 checklist, row by row

| # | Row | Verdict | Evidence |
|---|---|---|---|
| 1 | Re-run `check-migration-version-collision.sh V2.2.33` | **VERIFIED** | Re-run by me from the worktree root: *"Fetching remotes … **FREE: V2.2.33 is not claimed on any remote branch.** RESULT: clear."*, exit 0. ⚠ Still must be re-run immediately before merge — a sweep cannot see a branch pushed after it ran |
| 2 | Copy the evidence SQL into `db/migration/` | **VERIFIED (with 2 intended deltas)** | `diff` of `SBDEV-3410-evidence/V2.2.33__stockrecord_view.sql` vs the committed file: only (a) the header's draft/proof-read preamble replaced by the frozen-numbers note, (b) the DO block rewritten with its new ⚠ paragraph. Body of statements 1 and 2 byte-identical |
| 3 | Proof-read the CRC-frozen header numbers | **VERIFIED** | Every number re-derived independently — §C |
| 4 | Post-index `EXPLAIN` under `force_generic_plan`, recorded into §3.2 | **BLOCKED** | See A-2. Index absent on dev; §3.2 unchanged |
| 5 | Write the IT first, confirm it fails for the right reason | **VERIFIED** | `gate-run2.log`: `Tests run: 4, Failures: 1, Errors: 3` — three `PSQL ERROR: relation "stockrecord_view" does not exist` and one failure on the absent index. That is exactly what the class javadoc predicts (*"every test here fails with … 42P01 … except `index_shouldExistOnClientIdAndCreated`, which fails on the absent index"*) |
| 6 | Three mutation checks | **PARTIAL (2 of 3)** | Rows 1–2 verified two ways — §D. Row 3 MISSING — §A-1 |
| 7 | Ownership note (plain `CREATE`, schema-level risk only) | **VERIFIED as written; superseded in the working tree** | The committed header asserts *"this is a plain `CREATE` … needs only `CREATE` on schema public"*. True **given** non-existence, which I confirmed on every reachable DB (§E). The working tree has since sharpened this to say the safety rests on the non-existence premise and not on the statement form, and that 2 of the 3 active PRD tenant DBs are unverified — a genuine improvement, since `CREATE OR REPLACE` on an *existing* view needs ownership and would reproduce the `V2.2.07` stall |

---

## C. The CRC-frozen numbers — re-derived, all correct

`mcp__wms2-wineco-dev__execute_sql`, `current_database() = dev_wh01_om1`, 2026-09-18:

| Header claim | Re-derived | Match |
|---|---|---|
| 8,808 `itemdata` rows | `count(*) FROM itemdata` → **8808** | ✅ |
| 8,721 distinct `item_nr` | `count(DISTINCT item_nr)` → **8721** | ✅ |
| **71** `item_nr` STRINGS shared between shippers | `count(*) FROM (SELECT item_nr FROM itemdata GROUP BY item_nr HAVING count(*)>1) d` → **71** | ✅ |
| **87** EXCESS ROWS | `sum(c-1)` over those groups → **87** | ✅ |
| ARW (`client_id 60500`) 873,021 `stockrecord` rows | **873021** | ✅ |
| item_nr-only join turns it into 887,856 | **887856** | ✅ |
| inventing 14,835 phantom entries | 887856 − 873021 = **14835** | ✅ |
| pair join multiplies exactly 0 | pair-join count → **873021** | ✅ |
| whole table 9,726,795 → 9,726,795 | `count(*) FROM stockrecord` → **9726795** | ✅ |
| 0 of 9,726,795 rows fail to resolve | **0** — positive control: same query with the predicate poisoned to `i.item_nr = sr.itemdata \|\| '_NOPE'` returns **9726795**, so the instrument reports non-matches and the zero is a measurement | ✅ |

The 71-vs-87 distinction the header goes out of its way to make is correct in both directions.

**One CRC-frozen wording nit (Low, cosmetic, unfixable after first apply).** The header opens *"now
that this script **has run** … They were verified … **before the first apply**"*. It has not run on any
tenant: dev's `flyway_schema_history` max is `2.2.32`, the view is absent on all five reachable
databases and the index is absent on all five. The sentence reads, permanently, as if the script were
already applied somewhere. The numbers it protects are right; only the tense is wrong. Worth one
minute's thought before merge, because after the first real apply it cannot be changed.

---

## D. The two performed mutation checks — confirmed by a second, independent instrument

I did not take the implementer's logs at face value. I derived the expected mutant counts myself, from
the fixture's shape, as a `VALUES`-CTE simulation executed read-only on `dev_wh01_om1`:

| quantity | my independent derivation | the mutation logs |
|---|---|---|
| base `stockrecord` rows | 3 | 3 |
| correct pair-join LEFT view | 3 | green |
| **mutant: `ON i.item_nr = sr.itemdata`** | **5** | `r-mut1.log`: *"stockrecord_view returned **5** rows for **3** stockrecord rows — the join **MULTIPLIED**"* |
| **mutant: `LEFT` → `INNER`** | **2** | `r-mut2.log`: *"returned **2** rows for **3** … the join **DROPPED** rows"* |
| orphan survivors under INNER | **0** | `r-mut2.log`: *"the stockrecord row carrying SKU 'SBDEV3410-NO-SUCH-SKU' is **ABSENT** … an INNER JOIN silently DELETED it"* |

Both kills are **attributable**: each names the direction and the specific defect, and the
direction-aware `diagnosis` ternary (added after a first mutation run reported "MULTIPLIED" for a count
that had gone down) is doing real work — `r-mut2` prints the DROPPED branch, not the MULTIPLIED one.
`r-pristine.log` is green on the same harness, so the reds are the mutants and not the fixture.

**The positive controls are not vacuous.** Each asserts the trap exists *before* asserting it is not
sprung, and each would fail on an empty or mis-seeded fixture:

- AC-P1a: *"the fixture must contain a SKU string held by two different shippers, otherwise an
  item_nr-only join has nothing to multiply and this test cannot fail"* — `isEqualTo(1L)`.
- AC-P1b: *"the fixture must contain a stockrecord row whose SKU resolves to no itemdata row,
  otherwise an INNER JOIN drops nothing and this test cannot fail"* — `isEqualTo(1L)`.

This matters exactly as the javadoc argues: a freshly-migrated database has **no** `itemdata` rows, so
`count(view) == count(table)` would read `0 == 0` and pass against any join. Building the fixture is
what makes the suite non-vacuous, and the controls are what prove the fixture was built.

**Two smaller notes, neither a defect:**

- `index_shouldExistOnClientIdAndCreated` carries no positive control, but its failure mode is
  `def == null` → red; a broken instrument cannot produce a false green here. Its
  `containsPattern("\\(client_id,\\s*created")` would also accept a *wider* index that merely leads
  with those two columns — acceptable, and arguably the right invariant.
- Under the multiplication mutant, `nameFor()` sees two rows and reads the first, so AC-P1c's outcome
  is not deterministic for that mutant. Harmless: AC-P1a is the attributable kill for it, and the log
  shows 2 failures for `mut1` regardless.

---

## E. The constraint guard — run against the DB, and probed for ways it could still be wrong

### E-1 The three claimed directions, re-executed

I lifted the committed predicate verbatim and ran it read-only on `dev_wh01_om1`:

| relation, expected column set | guard fires? | required |
|---|---|---|
| `public.itemdata`, `{client_id,item_nr}` | **true** | true ✅ |
| `public.stockrecord`, `{client_id,item_nr}` | **false** | false ✅ |
| `public.itemdata`, `{client_id,name}` | **false** | false ✅ |
| `public.itemdata`, `{item_nr}` | **false** | false ✅ |

The original defect the commit fixes is confirmed at the source: `pg_constraint.conkey` for
`uk3l3dgof3l6mc1dl7s3lmida65` is **`{20,10}`** (`item_nr` = attnum 10, `client_id` = attnum 20) against
the old `array_agg(attnum ORDER BY attnum)` of `{10,20}`. The pre-fix guard would indeed have RAISEd on
a tenant that **has** the constraint, failed `V2.2.33` and frozen that tenant's Flyway at `V2.2.32`.
The commit message's account of it is accurate.

Across every database this MCP set reaches, the guard passes:

| database | via | `contype='u'` on `itemdata` | guard |
|---|---|---|---|
| `dev_wh01_om1` | `wms2-wineco-dev` | 1 | **true** |
| `wh01_hydra_v2` (PRD) | `nywh-hydra-prd` | 1 | **true** |
| `wh01_hydra_v2` (UAT, `10.0.0.6`) | `nywh-hydra-uat` | 1 | **true** |
| `wh01_shipitez_v2` (UAT) | `c1wh-shipitez-uat` | 1 | **true** |
| `wh02_shipitez_v2` (UAT) | `nywh-shipitez-uat` | 1 | **true** |

Completeness: derived by querying each MCP alias directly. **Blind spot, and it is the one the plan
already names:** the three PRD aliases all resolve to `current_database() = wh01_hydra_v2`, so this is
**1 of the 3 active PRD tenant databases**. `wh01_shipitez_v2` and `wh02_shipitez_v2` on PRD are
unmeasured for the constraint, for view absence, and for the index name being free.

### E-2 Ways it could still be wrong — each probed, not assumed

| hazard | verdict |
|---|---|
| **Dropped columns (`attisdropped`)** | **Not reachable.** Dropping a column drops any constraint over it, so `conkey` can never name a dropped attnum, and attnums are unique per relation so no coincidental match exists. The absent `attisdropped` filter is harmless |
| **A 3-column constraint `(client_id, item_nr, x)`** | **Correctly rejected** — sorted set is `{client_id,item_nr,x}` ≠ `{client_id,item_nr}`, so the guard RAISEs. That is the right answer: a wider unique constraint does **not** imply the pair is unique |
| **A partial unique constraint** | **Impossible by construction** — a `UNIQUE` *constraint* cannot carry a predicate in PostgreSQL. Only an index can, which is the next row |
| **A bare `CREATE UNIQUE INDEX` with no CONSTRAINT** | ⚠ **REAL GAP in the committed form.** Join removal (`analyzejoins.c`) reads **`pg_index`**, not `pg_constraint` — it needs a unique index that is `indimmediate`, `indisvalid` and non-partial, and does not care whether a constraint backs it. A tenant carrying only a unique *index* on the pair is **fully correct** for this view, yet the committed guard RAISEs on it and freezes its Flyway — the exact failure mode this commit exists to remove, in a different disguise |
| **A `DEFERRABLE` unique constraint** | ⚠ **REAL GAP in the committed form, in the opposite direction.** A non-`indimmediate` unique constraint is not usable for join removal, so the elimination the view depends on is silently lost — but `contype='u'` matches and the guard **passes**. A false green |
| **`NULLS NOT DISTINCT` / nullable `item_nr`** | Benign — `i.item_nr = sr.itemdata` never matches a NULL, so no multiplication arises |
| **Schema resolution** | The guard qualifies (`'public.itemdata'::regclass`) and so does the view (`public.stockrecord_view`, `public.stockrecord`, `public.itemdata`, `public.client`). ⚠ The **index** statement does not: `CREATE INDEX index_stockrecord_client_created ON stockrecord (…)` resolves through `search_path`, unlike the `db/migration` precedent (`CREATE INDEX … ON public.adviceposition …`). **Low** — cosmetic today, a one-word fix |

Neither E-2 gap is live on any reachable database: all five carry a unique constraint whose index is
`indisunique`, `indimmediate`, `indisvalid` and non-partial. So the committed guard is **correct in
practice today**, and both gaps are latent.

**The working tree has already closed both** — the DO block there matches on `pg_index` with
`indisunique AND indimmediate AND indisvalid AND indpred IS NULL` and `indnkeyatts` to exclude
`INCLUDE` columns. I verified that form derives `['client_id','item_nr']` for
`uk3l3dgof3l6mc1dl7s3lmida65` on `dev_wh01_om1` and returns nothing matching for `itemdata_pkey` or the
four non-unique indexes, and that a from-scratch `db/migration` migrate under it is green
(`StockrecordViewSchemaIT` → `Tests run: 5, Failures: 0, Errors: 0`;
`LockOverviewViewIT` + `ReplenishMonitorVisibilityIntegrationTest` → `Tests run: 11, Failures: 0, Errors: 0`).
**That is an improvement on `bfb5b860` and should land.**

⚠ **One thing in the working tree to look at before it lands, because it contradicts a decision the
plan records as made:** the index statement there is now `CREATE INDEX **IF NOT EXISTS**
index_stockrecord_client_created …`. §3.2 states the opposite explicitly — *"The statement is written
**without** `IF NOT EXISTS`, exactly as decided … (a) it was not what was decided and (b) `V2.2.32`'s
own header records that Postgres checks ownership BEFORE `IF NOT EXISTS`"*. The change may well be
deliberate and is harmless in itself, but it is a silent reversal of a recorded decision; either the
decision or the plan text should move, not neither.

---

## F. Design conformance — §3.1 / §3.2

| §3.1 / §3.2 requirement | Verdict | Evidence |
|---|---|---|
| Column list is a **strict superset** of `stockrecord` | **VERIFIED** | The view projects 24 `sr.*` columns; `information_schema.columns` for `public.stockrecord` on `dev_wh01_om1` returns exactly 24, name-for-name identical. Plus `i.id AS item_id`, `i.name AS item_name`, `c.cl_nr`, `c.name AS cl_name` — the four §3.1 names. Blind spot: derived against dev, which may carry columns `db/migration` does not; the reverse is covered by the IT, whose `SELECT *`-shaped reads resolve on a migration-built schema |
| `version` / `entity_lock` projected for shape parity | **VERIFIED** | Both present; the header carries the *"the mapped entity must NOT declare `@Version`"* warning for P2 |
| **Both** joins `LEFT` | **VERIFIED** | `LEFT JOIN public.itemdata i …` and `LEFT JOIN public.client c …` |
| Join key is the **pair** `(client_id, item_nr)` | **VERIFIED** | `ON i.client_id = sr.client_id AND i.item_nr = sr.itemdata` |
| Client join on the PK | **VERIFIED** | `ON c.id = sr.client_id`; `client` has a PK on all five reachable databases (`contype='p'` → 1 each), which is what licenses the elimination claim |
| Index on `(client_id, created)` | **VERIFIED** | `CREATE INDEX index_stockrecord_client_created ON stockrecord (client_id, created DESC);` — byte-identical to §3.2's decided DDL |
| `NOT CONCURRENTLY`, with the reason | **VERIFIED** | Stated in the second statement's header |
| Third statement asserts the constraint by **column set, not by generated name** | **VERIFIED** | §E |
| Keyword search not widened to `item_name` / `cl_name` | **VERIFIED** | No `WHERE` in the view at all; the header carries the DO-NOT-WIDEN paragraph with its 2.5× measurement |

---

## G. Nothing stray is committed

```
git show --stat bfb5b860
 src/main/resources/db/migration/V2.2.33__stockrecord_view.sql     | 160 ++++++
 src/test/java/net/aim_ai/wms/integration/schema/StockrecordViewSchemaIT.java | 324 +++++
 2 files changed, 484 insertions(+)

git log --oneline origin/develop..HEAD   →  bfb5b860 only
git diff --stat origin/develop...HEAD    →  the same 2 files
git status --porcelain (at lane start)   →  clean
```

Two files, additions only, one commit ahead of `origin/develop`. No build output, no scratch files, no
plan or evidence files, no unrelated edits. Commit message ends with the required
`Co-Authored-By` line. ✅

---

## H. Evidence re-run by this lane (not taken on trust)

| command | result | claimed |
|---|---|---|
| `mvn -o verify -Dit.test=StockrecordViewSchemaIT -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` | `Running …StockrecordViewSchemaIT` → **`Tests run: 4, Failures: 0, Errors: 0, Skipped: 0`**, **BUILD SUCCESS** | 4/4 green ✅ |
| `mvn -o clean compile` | **BUILD SUCCESS** | ✅ |
| `mvn -o clean test` (full unit lane, with `clean` — so no stale `target/test-classes`) | **`Tests run: 6741, Failures: 0, Errors: 0, Skipped: 1`**, **BUILD SUCCESS**, 02:52 | *"6741 run, 0 failures (baseline 0)"* ✅ exact match |
| `bash src/main/resources/db/check-migration-version-collision.sh V2.2.33` | *"FREE: V2.2.33 is not claimed on any remote branch. RESULT: clear."* | ✅ |
| `mvn -o verify` (full failsafe lane) | **contaminated — not a verdict.** See the ⚠ section at the top | never claimed |

Lane hygiene note: the surefire run used `clean`, so it cannot be reading a deleted test class's stale
XML, and the selector matched a real class in every case (the `Running …` line is present, and the
totals moved), so no row here is a no-match false pass.

---

## I. Prerequisite spot-checks (§5.1, the ones P1 depends on)

Measured 2026-09-18, each with a positive control where a zero is load-bearing:

| check | dev | hydra PRD | hydra UAT | shipitez UAT c1wh | shipitez UAT nywh |
|---|---|---|---|---|---|
| `stockrecord_view` in `information_schema.views` | **0** | **0** | **0** | **0** | **0** |
| control: `stock_view` from the same query | 1 | 1 | 1 | 1 | 1 |
| `index_stockrecord_client_created` in `pg_indexes` | **0** | **0** | **0** | **0** | **0** |
| `client` PK present | 1 | 1 | 1 | 1 | 1 |

So the view name and index name are free and `CREATE` / plain `CREATE INDEX` are safe — **on these
five**. Same blind spot as §E-1: the three PRD aliases are one database, so both ShipItEZ PRD
databases remain unverified for all three of view absence, index-name freedom and the unique
constraint. The working tree's header now says this in the file itself, which is the right place for it.

---

## J. Summary of findings

| # | Severity | Finding |
|---|---|---|
| J-1 | **Medium** | §5.2 P1's third mutation row has no killing test — `constraintIsAsserted` does not exist in `bfb5b860`. The `DO $$` block has no standing regression guard. §7.2 carries the full recipe; assert SQLSTATE `P0001`, not message text (§A-1) |
| J-2 | **Medium (sequencing, not a defect)** | The post-index `force_generic_plan` re-measurement is unrecorded and *cannot* be taken before merge — the index does not exist on dev. Move it to a post-merge action on the ticket rather than leaving it as an unchecked P1 box (§A-2) |
| J-3 | **Low (latent, closed in the working tree)** | The committed guard matches `pg_constraint`, but the planner reads `pg_index`. A bare unique *index* → false RAISE and a frozen tenant; a `DEFERRABLE` constraint → false pass with the elimination lost. Not live on any of 5 reachable DBs. The working tree's `pg_index` form fixes both and is verified green (§E-2) |
| J-4 | **Low** | The working tree adds `IF NOT EXISTS` to the index, silently reversing a decision §3.2 records as made with a stated rationale. Either land it and update §3.2, or drop it (§E-2) |
| J-5 | **Low, CRC-frozen** | The header's opening sentence reads as though the script has already been applied; it has not (dev is at `2.2.32`). Correct the tense before the first real apply or it is permanent (§C) |
| J-6 | **Low, cosmetic** | The index statement is the only unqualified relation reference in the file; `db/migration` precedent qualifies with `public.` (§E-2) |
| J-7 | **Process** | Nobody has a clean full failsafe-lane result for this migration. Mine was contaminated by a concurrent build in the shared worktree. Re-run `mvn -o verify` once, alone, before merge (⚠ section) |

**No finding disputes the correctness of the view, the index, the guard, the fixture, or the frozen
numbers.** Everything the commit claims, I re-derived and it held.
