# SBDEV-3410 P1 — re-review of the fix commits (`bfb5b860..HEAD`)

**Lane:** re-review of the two previously-ungraded fix commits. Read-only; nothing patched.
**Subject:** `git diff bfb5b860..HEAD` — `e8411c6f` (review-lane fixes) and `966228c6` (guard pin + three more fixes).
**Worktree:** `.claude/worktrees/wms2-api/SBDEV-3410`, branch `feature/SBDEV-3410-p1-stockrecord-view-migration`.
**`git status` at start of lane: clean** (empty `--porcelain`). Quiescent as promised.
**Date:** 2026-09-19.

---

## Verdict

**2 Medium, 4 Low. No High.**

The delta is a real improvement — the `pg_index` move is the right call, `nameFor` is now correct,
and AC-P1f closes a genuine coverage gap that mutation-checking structurally could not.

But the answer to *"assume a third defect is likely"* is **yes, there is one**, and it is worse than a
fresh mistake: **the repo already contains the correct, reviewed form of this exact query, thirteen
migrations earlier, and the new guard is a weakened copy of it.**
`V2.2.20__authorization_join_table_primary_keys.sql` matches a unique index over a named column set
using the same `unnest(indkey) WITH ORDINALITY` construction — and additionally carries
`ix.indexprs IS NULL`, `ix.indnkeyatts = array_length(r.cols, 1)` and `ix.indisready`, each of which
V2.2.33 drops. The first two independently close the hole documented as **M-R1** below.

Separately, one CRC-frozen prose claim is **false as written** (**M-R2**), and three Low findings from
`p1-code-review.md` (L3, L6, L8) were silently dropped with no disposition anywhere.

---

## 1. The guard — the third defect (M-R1)

### M-R1 — Medium: a unique index on `(client_id, item_nr, <expression>)` passes the guard but does not confer the invariant

`src/main/resources/db/migration/V2.2.33__stockrecord_view.sql`:

```sql
    SELECT 1 FROM pg_index ix
    WHERE ix.indrelid = 'public.itemdata'::regclass
      AND ix.indisunique AND ix.indimmediate AND ix.indisvalid
      AND ix.indpred IS NULL
      AND (SELECT array_agg(a.attname::text ORDER BY a.attname::text)
           FROM unnest(ix.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
           JOIN pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = k.attnum
           WHERE k.ord <= ix.indnkeyatts)
          = ARRAY['client_id', 'item_nr']::text[]
```

An **expression** key column stores `0` in `indkey`. `pg_attribute` has no `attnum = 0`, so the inner
`JOIN` **silently drops it** — the aggregate reports only the plain columns, and the index is graded as
though the expression column were not there.

Confirmed on `dev_wh01_om1` that expression keys really are `indkey = 0` and really do vanish from this
aggregate (13 such indexes, every one yielding `colset = NULL`):

```
tbl                      | idx                                        | indkey | indisunique | colset
stockrecord              | index_stockrecord_itemdata                 | 0      | False       | None
customerorder_position   | index_customerorder_position_number_lower  | 0      | True        | None
unitload                 | index_unitload_labelid_lower               | 0      | False       | None
```

No mixed column+expression index exists in any reachable database, so I graded the three shapes by
substituting the `indkey`/`indnkeyatts` values directly (no DDL, nothing mutated):

| shape | `indkey` / `indnkeyatts` | aggregated colset | **guard today** | with `indnkeyatts = 2` |
|---|---|---|---|---|
| A: `UNIQUE (client_id, item_nr)` — correct | `{20,10}` / 2 | `{client_id,item_nr}` | ✅ pass | ✅ pass |
| B: `UNIQUE (client_id, item_nr) INCLUDE (name)` — correct | `{20,10,5}` / 2 | `{client_id,item_nr}` | ✅ pass | ✅ pass |
| **C: `UNIQUE (client_id, item_nr, lower(expr))` — NOT the pair** | `{20,10,0}` / 3 | `{client_id,item_nr}` | **❌ passes** | ✅ correctly rejected |

Shape C is unique on a *triple*. It permits two `itemdata` rows with the same `(client_id, item_nr)`,
so the view multiplies and join elimination is lost — **precisely the outcome the guard exists to
prevent** — while the guard reports the tenant healthy. The failure is silent in the direction the
header itself describes: *"Hibernate dedupes by @Id inside the persistence context, so the page content
silently repeats one row while page.totalElements … reports the inflated figure."*

**This is not a hypothetical idiom in this codebase.** `db/migration` already indexes
`lower((col)::text)` in 13 places, and `index_customerorder_position_number_lower` is a **unique**
expression index. A tenant rebuilt with a lower-cased SKU uniqueness rule is exactly the drift class
the guard was written for.

**The fix already exists in this repo.** `V2.2.20__authorization_join_table_primary_keys.sql`:

```sql
            FROM pg_index ix
            ...
              AND ix.indisunique
              AND ix.indpred  IS NULL
              AND ix.indexprs IS NULL
              -- indisvalid/indisready: the residue of a failed CREATE UNIQUE INDEX CONCURRENTLY is
              -- indisunique=true but indisvalid=false. It enforces nothing, ...
              AND ix.indisvalid
              AND ix.indisready
              AND ix.indnkeyatts = array_length(r.cols, 1)
              AND (
                    SELECT array_agg(a.attname::text ORDER BY a.attname)
                      FROM unnest(ix.indkey::smallint[]) WITH ORDINALITY AS k(attnum, ord)
                      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
                     WHERE k.ord <= ix.indnkeyatts
                  ) = v_cols_sorted
```

Same construction, **plus** the three predicates V2.2.33 drops. Either `indexprs IS NULL` or
`indnkeyatts = 2` closes shape C on its own; the house idiom carries both. Recommend adding both, to
match precedent rather than invent a third variant of this query:

```sql
      AND ix.indexprs IS NULL
      AND ix.indnkeyatts = 2
```

This is CRC-frozen prose *and* frozen behaviour — after first apply it cannot be corrected in place.

> The V2.2.33 header presents the `pg_index` move as newly-derived reasoning
> (*"MATCHED ON pg_index, NOT pg_constraint, because pg_index is what the PLANNER reads"*). It is
> correct, but it is also **already the repo's idiom**, and the existing copy is stronger. A
> `grep -n pg_index src/main/resources/db/migration/*.sql` would have surfaced it.

### The rest of the lead's checklist for the guard — checked, and clean

| concern | verdict | evidence |
|---|---|---|
| `indnkeyatts` on **PostgreSQL 14** | ✅ **exists and works** | Ran the guard's exact predicate on `nywh-hydra-prd` = `wh01_hydra_v2`, **PostgreSQL 14.23** → `guard_passes_on_pg14_prd = true`. `indkey::int2[]`, `WITH ORDINALITY` and `indnkeyatts` all execute. (Added in PG 11.) The pinned test image is `postgres:14-alpine` (`AppPostgresDBContainer.java:31`). |
| `attisdropped` | ✅ not reachable — **but my empirical control was vacuous, see below** | `ALTER TABLE … DROP COLUMN` drops every index whose key references the column, so `indkey` cannot name a dropped attribute. Settled by documented semantics, **not** by measurement. |
| system columns (`attnum < 0`) | ✅ not reachable | PostgreSQL forbids indexing system columns. Had one existed, the `JOIN` would drop it like an expression column — same mechanism as M-R1. |
| expression columns (`attnum = 0`) | ❌ **M-R1** | above |
| `indislive` / `indisready` | ✅ adequately covered, one belt-and-braces gap | `RelationGetIndexList` filters `indislive` upstream, and `indisvalid` is what `plancat.c` tests. `indisvalid = true` with `indisready = false` is not reachable in normal operation (CIC sets `indisready` first). V2.2.20 still carries `indisready`; adding it costs nothing and matches precedent. **Low, optional.** |
| index on a **different table** via bad `regclass` | ✅ clean | `ix.indrelid = 'public.itemdata'::regclass` and the join uses `a.attrelid = ix.indrelid`, so table identity is consistent throughout. |
| `search_path` | ✅ clean | Every relation reference in the guard is schema-qualified. `pg_catalog` is implicitly first in `search_path` and cannot be displaced without an explicit `SET`. |
| collation | ✅ clean | `ORDER BY attname::text` is collation-dependent, but the only two strings are `client_id` and `item_nr`; `c` < `i` in every collation including `C`. Array `=` uses equality, not collation. |
| `indpred IS NULL` vs the planner | ✅ behaviour right, **prose wrong** — see L-R3 | Stricter than the planner (which accepts a partial index with `predOK`), but correctly so: a partial unique index does not guarantee global non-multiplication. |
| `indimmediate` excludes `DEFERRABLE` | ✅ correct | `index_constraint_create()` sets `indimmediate = !deferrable`, so *any* `DEFERRABLE` declaration — including `INITIALLY IMMEDIATE` — yields `indimmediate = false`. The header's claim holds. |
| a `PRIMARY KEY` over the pair | ✅ correctly accepted | `indisunique`/`indimmediate`/`indisvalid` all true for a PK. This is the direction the old `contype = 'u'` form got wrong (was L2). |
| live behaviour on the real constraint | ✅ | `uk3l3dgof3l6mc1dl7s3lmida65` → `indkey = '20 10'`, `indnkeyatts = 2`, `colset = {client_id, item_nr}` → guard passes on both dev (PG 16) and prd (PG 14). |

**⚠ Failed control, stated rather than hidden.** My `attisdropped` query returned
`index_keys_on_dropped_cols = 0`, but its positive control `count(*) FROM pg_attribute WHERE attisdropped`
also returned **0** on all three databases I tried (`wms2-wineco-dev`, `nywh-hydra-prd`, `wms1-wineco`).
No reachable database contains a dropped column at all, so that zero is **vacuous** — a broken
instrument and a true zero are indistinguishable here. The `attisdropped` verdict above rests on
PostgreSQL's documented drop-cascade semantics only.

---

## 2. AC-P1f — the guard pin

**The design is right and the gap it closes is real.** Mutation-checking a guard proves the assertion is
*sensitive*; only a pin protects its *existence*, and the revision log's own evidence (delete the block →
6 run, 1 failure, AC-P1f alone) is the asymmetry that made the gap invisible. Reading the block from the
classpath rather than restating it is the correct choice.

| lead's question | verdict |
|---|---|
| **Extraction robust?** | ✅ for the file as it stands. Exactly **one** `DO $$` and one `END $$;` in V2.2.33 (`grep -n '\$\$'` → lines 172, 187 only), and no other `$$` anywhere, so there is no nested-dollar-quote ambiguity. |
| **A later migration adds a second `DO` block?** | ✅ not reachable for this file. V2.2.33's CRC freezes on first apply; it cannot gain a second block afterwards. Added *before* first apply, `indexOf` would grab the first block and the `.contains("pg_index")` assertion would almost certainly fail — i.e. it fails loudly, not silently. |
| **Block deleted?** | ✅ handled explicitly. `start < 0` → `guard = ""` → `assertThat("").contains("pg_index")` fails with the intended message. |
| **Can the dropped constraint leak?** | ✅ **no.** `finally { c.rollback(); }` wraps the inner `try`-with-resources, so an `AssertionError` thrown by `assertThatThrownBy` still rolls back before the connection closes. The follow-up `scalar(...)` opens a *fresh* connection and asserts the constraint count is back to 1. No parallel execution is configured (no `junit-platform.properties` anywhere under `src/test`, no `parallel`/`forkCount`/`junit.jupiter.execution` in `pom.xml`), so the `ACCESS EXCLUSIVE` lock cannot collide with a sibling test. |
| **Is `P0001` too loose?** | ✅ **correctly tight here.** The extracted block contains exactly one `RAISE EXCEPTION` and no `ERRCODE`, so `P0001` is reachable only via that statement. The alternative failure modes are *different* SQLSTATEs — the historical `name[] = text[]` bug was `42883`, a syntax break is `42601` — and each of those correctly reds the test rather than passing it. Asserting the message text instead would have coupled the test to CRC-frozen prose. |

### L-R4 — Low (actionable, contrived): a block-commented-out guard survives the pin

Deleting the guard is caught. Commenting it out with `--` is also caught: the extracted text becomes
`DO $$\n-- BEGIN\n…`, which fails to parse as `42601 ≠ P0001`. But **wrapping it in `/* … */`** leaves
the inner text intact, so extraction yields a clean block that executes standalone and raises `P0001` —
the test passes while the migration's guard is inert.

Cheap closure: assert the block is not inside a block comment, or simply assert the file's guard offset
is not preceded by an unclosed `/*`. Genuinely contrived; reporting it because the lead asked whether
extraction is robust, and this is the one path where it is not.

---

## 3. AC-P1e — the superset pin

**The closed-set assertion is the right call**, and `containsExactly` is safe here despite being
order-sensitive: `added` is a `TreeSet<String>`, and natural String order really is
`cl_name` < `cl_nr` < `item_id` < `item_name` (`'a'` < `'r'` at index 4; `'i'` < `'n'` at index 5), matching
the literal. Confirmed green in `target/failsafe-reports/` (6/6, see §6). The stated blind spot — names
only, nothing about type, order or nullability — is accurate and correctly disclosed.

### L-R1 — Low (actionable): the `added` assertion reports the wrong direction on a dropped joined column

```java
        assertThat(added)
            .as("%s adds columns beyond the four the design specifies. A stray projected column becomes "
                + "part of a CRC-frozen migration's contract.", VIEW)
            .containsExactly("cl_name", "cl_nr", "item_id", "item_name");
```

`missing` only covers `base \ view`. A **joined** column that the view fails to project — say `item_name`
— is not in `base`, so `missing` cannot see it; `added` becomes `{cl_name, cl_nr, item_id}` and *this*
assertion fires, announcing *"adds columns beyond the four"* for a defect that **dropped** one.

This is the same defect class the team deliberately fixed in AC-P1a two commits earlier, in `bfb5b860`'s
own words:

> *"An earlier revision hard-coded "MULTIPLIED"; mutation-checking the INNER-JOIN mutant showed it
> reporting "MULTIPLIED" for a count that had gone DOWN … A red for the wrong stated reason is not an
> attributable kill."*

The revision log claims the `drop a projected column` mutation is *"killed by AC-P1e, names the
unprojected column"* — true for a **stockrecord** column (via `missing`), but for one of the four
**joined** columns the message names the wrong direction. Fix as AC-P1a was fixed: branch the
description on which set is non-empty, or split into two assertions.

---

## 4. `nameFor` — ✅ correct

```java
                List<String> names = new ArrayList<>();
                while (rs.next()) {
                    names.add(rs.getString(1));
                }
                assertThat(names)
                    .as("expected EXACTLY one %s row for client_id %d and SKU '%s'. ...")
                    .hasSize(1);
                return names.get(0);
```

Drains the cursor and asserts `hasSize(1)`, so the stated contract is now the enforced contract and the
`item_nr`-only mutant fails deterministically instead of ~50% of the time. `ORDER BY item_name` makes
`names.get(0)` deterministic (redundant under `hasSize(1)`, but harmless). The javadoc records the old
defect and why it mattered. **No finding.**

---

## 5. Migration header prose — read as permanent

### M-R2 — Medium: *"5 of 5 CREATE INDEX statements elsewhere in db/migration carry IF NOT EXISTS"* is false as written, and freezes

`V2.2.33__stockrecord_view.sql`:

```
-- Flyway -- the very failure class this file exists to avoid. 5 of 5 CREATE INDEX statements elsewhere
-- in db/migration carry IF NOT EXISTS. The plan's §3.2 is updated to match; this note exists so the
-- divergence is never silent.
```

Census of **executable** statements (comment mentions excluded by reading each hit, not by counting lines):

| scope | `CREATE [UNIQUE] INDEX` statements | of which `IF NOT EXISTS` |
|---|---|---|
| `V2.2.00__base_v2_schema.sql` | **115** (113 `CREATE INDEX` + 2 `CREATE UNIQUE INDEX`, lines 3876 & 3883) | **0** |
| `V2.2.01` … `V2.2.32` | **5** (V2.2.13:64, V2.2.25:423, V2.2.30:39, V2.2.30:46, V2.2.31:94) | **5** |
| **`db/migration` as named** | **120** | **5** |

So the claim is true only if *"db/migration"* silently means *"the delta migrations"*. Against the
directory it names, it is **5 of 120**. The base dump is a `pg_dump` that legacy tenants were baselined
past — which is a perfectly good reason to exclude it, but the header does not say so, and after first
apply it can never say so.

The stated derivation is also wrong, in both the header's source (`p1-code-review.md` L1) and the plan:

> §3.2: *"derived by `grep -c 'CREATE INDEX' db/migration/*.sql` cross-checked against each hit"*

That command returns **113 for `V2.2.00__base_v2_schema.sql` alone**, and over-counts comments in
V2.2.20 (1), V2.2.25 (1) and V2.2.33 (4). It cannot produce 5.

**Suggested frozen wording:** *"5 of 5 CREATE INDEX statements in the delta migrations (V2.2.01–V2.2.32)
carry IF NOT EXISTS; the V2.2.00 base dump's 115 do not, but it is a pg_dump that legacy tenants were
baselined past."*

Same correction is needed in the plan's §3.2 (line 477), which is *not* frozen and can still be fixed.

> **Instrument note.** `grep` here is `ugrep`. Both files are plain text so the binary-skip trap does not
> apply, and my `IF NOT EXISTS` pattern has a **positive control in the base dump**: it matches exactly
> once there, on `CREATE SCHEMA IF NOT EXISTS public;` (line 25). The pattern demonstrably works in that
> file, so *"0 `CREATE INDEX … IF NOT EXISTS` in V2.2.00"* is a true zero, not a broken instrument.

### L-R3 — Low (actionable, frozen): *"needs a unique index that is immediate, valid and non-partial"* is imprecise

```
-- ⚠ MATCHED ON pg_index, NOT pg_constraint, because pg_index is what the PLANNER reads. Join removal
-- (analyzejoins.c) needs a unique index that is immediate, valid and non-partial -- it does not care
-- whether a CONSTRAINT backs it.
```

The planner does **not** require non-partial. `rel_supports_distinctness` (analyzejoins.c) and
`relation_has_unique_index_for` (indxpath.c) both accept `ind->indpred == NIL || ind->predOK` — a partial
unique index whose predicate is proven true for the query is usable.

The guard's `indpred IS NULL` is nonetheless **correct and should stay**: a partial unique index does not
guarantee the *row-count* invariant across the whole view, which is the stronger of the two reasons this
block exists. Only the stated justification is wrong, and it is about to become unfixable. One-word fix
before first apply: say the guard requires non-partial *for the row-count invariant*, which is stricter
than what join removal alone needs.

### Frozen claims I checked and found **correct**

| claim | verdict |
|---|---|
| `8,808 / 8,721 / 71`, and 87 = the excess-row count | ✅ re-measured independently on `dev_wh01_om1`: `rows_total 8808`, `distinct_item_nr 8721`, `shared_across_shippers 71`. 8808 − 8721 = 87. The two-quantities distinction the header labours is real and correctly stated. |
| `9,726,795` stockrecord rows | ✅ `count(*) = 9726795`. |
| *"c1wh-shipitez-prd and nywh-shipitez-prd BOTH resolve to current_database() = wh01_hydra_v2"* | ✅ verified — and in fact **all three** prd aliases do, including `nywh-hydra-prd` (which legitimately is that database). |
| *"1 of the 3 active PRD tenant databases"* | ✅ `landlord-prd` → exactly 3 rows, all `active = true`: `wh01_hydra_v2` (hydra/nywh), `wh01_shipitez_v2` (shipitez/c1wh), `wh02_shipitez_v2` (shipitez/nywh). The two names called out as UNVERIFIED are correct. |
| *"(V2.2.32's header)"* attribution for the replay-vs-ownership reasoning | ✅ fair paraphrase — V2.2.32:35 reads *"checks ownership BEFORE IF NOT EXISTS, so `IF NOT EXISTS` does not make this safe on such a tenant."* |
| J-5 tense fix | ✅ *"THE NUMBERS IN THIS HEADER FREEZE ON THE FIRST APPLY"* — correct now; dev is still at `2.2.32`. |
| J-6 `public.` qualification | ✅ `CREATE INDEX IF NOT EXISTS index_stockrecord_client_created ON public.stockrecord (…)` — the file now has no unqualified relation reference. |
| the rewritten OWNERSHIP AND REPLAY paragraph | ✅ M3 addressed properly — it now says the safety rests on the non-existence premise rather than on the statement form, and states what `OR REPLACE` costs where the view *does* exist. |

**Cosmetic, not filed:** lines 1–6 assert the measurement date twice (*"on 2026-09-18, twice and
independently"* then *"Measured on dev_wh01_om1, 2026-09-18"*). Harmless duplication, but it too freezes.

---

## 6. Did the fixes deliver what was asked?

### `p1-code-review.md` — Mediums: **all four delivered**

| | asked | delivered |
|---|---|---|
| **M1** | `nameFor` claims "exactly one" without checking; AC-P1c nondeterministic under the mutant | ✅ `hasSize(1)` + `ORDER BY`; javadoc records the old defect |
| **M2** | nothing pins the "strict superset" invariant; no phase owns it | ✅ AC-P1e, set difference both ways — with the message-direction nit at **L-R1** |
| **M3** | OWNERSHIP AND REPLAY paragraph wrong about its own statement | ✅ rewritten; premise vs statement-form separated correctly |
| **M4** | "no tenant has it" verified on 1 of 3 PRD databases; two MCP entries misroute | ✅ recorded in the header with both unverified database names and a per-tenant pre-deploy instruction; independently re-verified above |

### `p1-code-review.md` — Lows: **2 of 8 fixed, 3 correctly deferred, 3 silently dropped**

| | status |
|---|---|
| **L1** — `IF NOT EXISTS` + `public.` qualification | ✅ fixed (`:144`) |
| **L2** — guard on `contype='u'` misses a bare unique index, passes a DEFERRABLE one | ✅ fixed (moved to `pg_index`) — **but re-opened in a new form, see M-R1** |
| **L4** — `index_stockrecord_client_id` becomes a redundant prefix | ⚪ review itself says *"Not a P1 defect"* — correctly deferred |
| **L5** — SHARE-lock cost not in the header | ✅ effectively addressed; the new `IF NOT EXISTS` note names *"the deploy-time SHARE lock"* |
| **L7** — `created DESC` implies `NULLS FIRST` | ⚪ review says *"no action in P1"* — correctly deferred |
| **L3** — guard runs **last**, after the 6.3 s / 276 MB build | ❌ **no disposition anywhere.** Still statement 3 of 3. |
| **L6** — frozen measurements taken on PG 16 while production is PG 14 | ❌ **no disposition anywhere.** The header still carries `7,356/7,647 ms`, `17.9 s`, `300–900x`, `~400x` with no server version, and these freeze. |
| **L8** — `scalar()` never checks `rs.next()`; index regex has no closing boundary | ❌ **no disposition anywhere.** Both unchanged: `rs.next(); return rs.getLong(1);` and `.containsPattern("\\(client_id,\\s*created")`. |

### L-R2 — Low (actionable, process): L3 / L6 / L8 were dropped without a decision

`grep -rn 'L3\b\|L6\b\|L8\b'` across the plan and `revision-log.md` returns **nothing**. The revision
log's third row reads only *"AC-P1f guard pin; J-4/J-5/J-6"* — the J-items were tracked, the L-items were
not. Per `~/.claude/CLAUDE.md` ("Address Low review findings too", Nam 2026-08-26), these need either a
fix or a recorded "won't fix" with a reason. **L6 is the one that matters**, because it is the only one
that becomes permanent on first apply.

L3 is worth acting on for a second reason the review already noted: asserting first costs nothing, and a
tenant that fails the guard currently pays a 6.3 s `SHARE` lock and 276 MB of WAL before being told.

### `p1-verifier.md` — J-items: **all actionable ones delivered**

| | status |
|---|---|
| **J-1** (Medium) — the `DO $$` block has no standing regression guard; assert SQLSTATE `P0001` | ✅ AC-P1f, asserting `P0001` exactly as prescribed |
| **J-3** (Low) — guard matches `pg_constraint`, planner reads `pg_index` | ✅ landed — **with M-R1 outstanding** |
| **J-4** (Low) — `IF NOT EXISTS` silently reverses §3.2 | ✅ landed *and* §3.2 updated (plan:470–479) *and* the divergence recorded in the header |
| **J-5** (Low, CRC-frozen) — header tense | ✅ fixed |
| **J-6** (Low, cosmetic) — unqualified index statement | ✅ fixed |
| **J-2** (sequencing) / **J-7** (process) | ⚪ post-merge / build-hygiene items, outside this delta |

### Test evidence (read, not run — no `mvn` per the brief)

`target/failsafe-reports/net.aim_ai.wms.integration.schema.StockrecordViewSchemaIT.txt`:

```
Tests run: 6, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 2.381 s
```

All six ACs present in the XML: `view_shouldNotMultiplyRows_…`, `view_shouldPreserveRow_…`,
`view_shouldProjectEveryStockrecordColumn_plusTheJoinedOnes`, `view_shouldResolveItemName_perShipper_…`,
`constraintGuard_shouldRaise_whenTheUniqueIndexIsAbsent`, `index_shouldExistOnClientIdAndCreated`.
Report timestamped `Sep 18 17:23`, i.e. after `966228c6` (17:18). The 6/6 claim checks out.

⚠ **I did not re-run anything.** This is a read of an existing artifact; J-7 (one clean solo
`mvn -o verify`) remains open and this lane does not discharge it.

---

## Findings summary

| id | sev | actionable? | one line |
|---|---|---|---|
| **M-R1** | **Medium** | **yes — freezes on first apply** | Guard passes a `UNIQUE (client_id, item_nr, <expression>)` index that does not confer the pair invariant. `V2.2.20` already carries the stronger house idiom; add `indexprs IS NULL` and `indnkeyatts = 2`. |
| **M-R2** | **Medium** | **yes — freezes on first apply** | *"5 of 5 CREATE INDEX statements elsewhere in db/migration carry IF NOT EXISTS"* is 5 of 120 as written; the stated `grep` derivation returns 113 for the base dump alone. Fix header + plan §3.2. |
| **L-R1** | Low | yes | AC-P1e's `added` assertion announces *"adds columns beyond the four"* when a **joined** column was dropped — wrong stated reason, the same class AC-P1a was fixed for. |
| **L-R2** | Low | yes (process) | `p1-code-review.md` L3, L6, L8 dropped with no disposition. **L6 freezes** (PG 16 measurements, PG 14 production). |
| **L-R3** | Low | yes — freezes | Header says join removal *"needs … non-partial"*; the planner accepts a partial index with `predOK`. The guard's stricter behaviour is right; the reason given is wrong. |
| **L-R4** | Low | marginal (noise-adjacent) | AC-P1f passes if the guard is wrapped in `/* … */`. `--` commenting and outright deletion are both caught. |
| — | note | optional | Adding `ix.indisready` alongside `indisvalid` would match `V2.2.20` exactly; not reachable as a defect. |

**Ordering if only some are taken:** M-R1 and M-R2 before first apply — both are permanent. L-R3 likewise
(it is frozen prose). L-R2's L6 likewise. L-R1 and L-R4 can land any time.

---

## Completeness statements and blind spots

- **"No High."** Derived by grading every changed hunk in `git diff bfb5b860..HEAD` (2 files, 105
  insertions / 4 deletions) against correctness, frozen-prose permanence, and the two prior reports'
  open items. **Blind spot:** I graded the delta only. `bfb5b860` itself and the plan document's
  ~1,800 lines were read for context, not audited.
- **"The guard has exactly one remaining hole."** Derived by enumerating every `pg_index` column the
  predicate reads or omits (`indisunique`, `indimmediate`, `indisvalid`, `indislive`, `indisready`,
  `indpred`, `indexprs`, `indkey`, `indnkeyatts`, `indnatts`, `indrelid`) and grading each against the
  planner's `rel_supports_distinctness` / `relation_has_unique_index_for` conditions, plus the lead's
  named list. **Blind spot:** I did not create a real shape-C index — no DDL was run anywhere. The
  verdict rests on substituting `indkey`/`indnkeyatts` values into the live predicate, which exercises
  the aggregation but not PostgreSQL's index-creation path.
- **"L3/L6/L8 have no disposition."** Derived by `grep -rn 'L3\b\|L6\b\|L8\b'` over the plan document
  and `revision-log.md` → zero hits, against a control of `grep -n 'J-[0-9]'` which returns 7 hits in
  `p1-verifier.md` and matching rows in the revision log. The instrument finds this shape of reference
  when one exists.
- **CREATE INDEX census.** Statements counted by reading every hit and classifying comment vs.
  executable, not by line count. Positive control for the `IF NOT EXISTS` pattern inside the base dump:
  one match (`CREATE SCHEMA IF NOT EXISTS public;`, `V2.2.00:25`). **Blind spot:** an index created
  inside a `DO` block via `EXECUTE format(...)` would be missed — the same blind spot §3.2 already
  states.
- **Database evidence.** `dev_wh01_om1` is **PostgreSQL 16.10**; production is **14.23**. Every
  catalog-shape claim above was confirmed on at least one PG 14 server (`nywh-hydra-prd`). All queries
  read-only; **nothing was mutated, no DDL, no transaction left open.**
- **Not covered by this lane:** P2/P3 scope, the entity mapping, `mvn` execution (forbidden by the
  brief), and whether the migration is correct against `wh01_shipitez_v2` / `wh02_shipitez_v2` — those
  two remain unreachable and the header correctly says so.
