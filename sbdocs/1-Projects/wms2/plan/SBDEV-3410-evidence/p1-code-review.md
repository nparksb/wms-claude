# SBDEV-3410 P1 — code review (read-only lane)

- **Subject:** commit `bfb5b860`, branch `feature/SBDEV-3410-p1-stockrecord-view-migration`
- **Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3410`
- **Files:** `src/main/resources/db/migration/V2.2.33__stockrecord_view.sql` (160 lines),
  `src/test/java/net/aim_ai/wms/integration/schema/StockrecordViewSchemaIT.java` (324 lines)
- **Scope:** plan §3.1 / §3.2 / §5.2 P1 only. P2–P6 not reviewed.
- **Date:** 2026-09-18
- **Verdict:** **no High findings. The view text and the guard logic are correct.** 4 Medium and
  8 Low below; 2 of the Mediums are one-line changes to the test (not the frozen migration), 1 is a
  frozen-comment accuracy defect, 1 is a verification gap I could not close from this lane.

---

## 0. What I verified independently (not taken from the commit message)

| Claim under test | Instrument | Result |
|---|---|---|
| Guard matches on a correct tenant | `mcp__wms2-wineco-dev` / `nywh-hydra-prd` / `nywh-hydra-uat` — ran the guard's exact `EXISTS(...)` predicate | `true` on all three |
| `conkey` really is `{20,10}` | `SELECT conkey FROM pg_constraint` on dev_wh01_om1 | `{20,10}`; `item_nr=10, client_id=20` — the commit message's narrative is accurate |
| The projection is a strict superset of `stockrecord` | `EXCEPT` both directions between the 24 projected names and `pg_attribute` on dev | `projected_but_missing: NONE`, `on_table_but_not_projected: NONE` — exact match |
| Join elimination actually happens | `EXPLAIN (COSTS OFF)` of the view body's `count(*)` on dev **and** prd | dev (PG 16.10): `Parallel Seq Scan on stockrecord sr` only. prd (PG 14.23): `Seq Scan on stockrecord sr` only. **Both joins eliminated on both major versions.** |
| `V2.2.33` is a free Flyway version | `git ls-tree` over all 309 `refs/remotes/origin/*` after `git fetch --all`, positive control on `V2\.2\.3` (returns the known 30/31/32 on many branches) | **No collision.** Blind spot: a branch pushed after this fetch |
| Fixture ids don't collide with seed data | `grep INSERT INTO public.client/itemdata` across `db/migration/` | base dump seeds `client` id `0` only; no `itemdata`/`stockrecord` seed rows. `9_903_41x` is safe |
| `client.id` is a PK (the other half of the invariance argument) | `pg_constraint` on dev | `client_pkey` present |

---

## MEDIUM

### M1 — The test claims "exactly one row" and does not check it; under the multiplication mutant AC-P1c is nondeterministic

`StockrecordViewSchemaIT.nameFor`:

```java
try (ResultSet rs = ps.executeQuery()) {
    assertThat(rs.next())
        .as("expected exactly one %s row for client_id %d and SKU '%s'", VIEW, clientId, SHARED_SKU)
        .isTrue();
    return rs.getString(1);
}
```

`rs.next()` proves *at least one*. The message says *exactly one*.

Under the mutant the file exists to kill — joining on `item_nr` alone — the query
`WHERE client_id = ? AND itemdata = ?` returns **two** rows for `CLIENT_A` (both `itemdata` rows match
on the shared string), in **no defined order**, because there is no `ORDER BY`. `nameFor` takes the
first. If PostgreSQL hands back `ITEMDATA_A` first, AC-P1c is **green against the mutant**.

This does not break the gate — `AC-P1a` kills that mutant deterministically on the cardinality
assertion — but AC-P1c's own stated contract is not enforced, in a file whose thesis is that every
control is non-vacuous. Fix is one line: collect the rows and assert `hasSize(1)` before reading
element 0, or add `ORDER BY` plus an explicit count.

### M2 — Nothing pins the "strict superset" invariant the header asserts, and no phase owns it

The migration header states a closed-set property:

> `-- COLUMN SET. Every stockrecord column is projected unchanged so the view is a strict superset of the`
> `-- table, plus item_id/item_name from itemdata and cl_nr/cl_name from client.`

I confirmed it holds today (§0, exact `EXCEPT` match, 24 columns). But it is an invariant over a table
that future migrations will alter, and **no test asserts it.** The IT's own javadoc disclaims it:

> `<li>Row COUNT and per-row SKU resolution only. This says nothing about the view's column list, its`
> `types, or the entity mapping — those are P2's {@code StockrecordViewRepositoryFilterIT} and the`
> `entity-reconciliation test, not this file.</li>`

P2's entity-reconciliation test (modelled on `ReplenishmentMonitorViewSchemaIT.entityResolvedColumns_shouldAllExistInTheView`)
checks the *entity→view* direction: that every mapped field resolves to a view column. It cannot see a
`stockrecord` column the view failed to project, because nothing maps it. So the superset invariant
has no owner in either phase.

The next migration that adds a column to `stockrecord` silently falsifies a frozen comment, and the
Stock Unit Record report silently lacks the column. Cheapest fix is ~6 lines in **this** file, which is
not frozen:

```sql
SELECT attname FROM pg_attribute WHERE attrelid='public.stockrecord'::regclass AND attnum>0 AND NOT attisdropped
EXCEPT
SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='stockrecord_view'
```

asserted empty. That is the query I used in §0; it runs in milliseconds against the already-started container.

### M3 — The OWNERSHIP AND REPLAY paragraph is wrong about its own statement, and the privilege claim only holds under the premise the hedge exists to survive

```
-- OWNERSHIP AND REPLAY. stockrecord_view does not exist on any tenant, so this is a plain CREATE and
-- needs only CREATE on schema public -- not the object ownership that froze wh01_hydra_v2 at V2.2.06 on
-- 2026-08-05 (see db/migration/README.md). CREATE OR REPLACE makes re-runs a no-op.
```

Three problems, all permanent (CRC32 covers comments):

1. **"this is a plain CREATE" is false about the statement text** — line 88 reads
   `CREATE OR REPLACE VIEW public.stockrecord_view AS`. The paragraph is arguing that *under the
   non-existence premise* `OR REPLACE` degenerates to `CREATE`. That is sound reasoning stated as a
   false fact, and the two sentences sit in tension: the first says the view cannot exist, the last
   justifies a hedge against it existing.
2. **The privilege claim is conditional and stated unconditionally.** `CREATE OR REPLACE VIEW` against
   a view that *does* exist requires **ownership of the view**, not `CREATE` on the schema —
   `ERROR 42501: must be owner of view stockrecord_view`. That is precisely the V2.2.06/`wh01_hydra_v2`
   stall the paragraph cites as the thing being avoided. On the one tenant where the hedge matters,
   the reassurance is inverted.
3. **"makes re-runs a no-op" is not a property of this file.** Flyway never re-runs a successful
   migration, and a failure rolls the whole script back (no `group`/`mixed` set —
   `StartupFlywayMigrator:292` configures only `locations`/`outOfOrder`/`baselineOnMigrate`, so
   PostgreSQL's per-migration transaction applies). More concretely, statement 2 (`CREATE INDEX`,
   see L1) is **not** idempotent, so the file as a whole is not replay-safe regardless. And if the
   view existed with a *different* shape, `CREATE OR REPLACE VIEW` does not overwrite it — it errors
   with `cannot change name of view column` / `cannot drop columns from view`. Useful behaviour, and
   the opposite of "no-op".

Not fixable in place. Worth a line on the ticket and, if a later migration touches this view, a
correction in that file's header (the `ReplenishmentMonitorViewSchemaIT` javadoc is the repo's
precedent for a retraction that lives outside the frozen file).

### M4 — "does not exist on any tenant" is verified on 1 of the 3 active PRD tenant databases; two MCP entries that look like coverage are misrouted

`mcp__landlord-prd` `tenant_db_configuration` has three active rows:

| tenant_id | warehouse | db |
|---|---|---|
| 1 | nywh | `wh01_hydra_v2` |
| 8 | c1wh | `wh01_shipitez_v2` |
| 8 | nywh | `wh02_shipitez_v2` |

**Both `mcp__c1wh-shipitez-prd` and `mcp__nywh-shipitez-prd` return `current_database() = 'wh01_hydra_v2'`.**
They are pointed at Hydra, not at either shipitez database. So what looked like a 5-database sweep is
3 distinct databases: `dev_wh01_om1` (PG 16.10), `wh01_hydra_v2` prd (PG 14.23), `wh01_hydra_v2` uat.

`wh01_shipitez_v2` and `wh02_shipitez_v2` — 2 of 3 PRD tenants — are **unverified** for all three
premises this migration rests on: view absence, index-name freedom, and the unique constraint. Hydra
prd/uat are both at Flyway head `2.2.32`, so V2.2.33 will run on the next deploy; the shipitez heads
are also unknown to me.

This is a verification gap, not a code defect, and it is the cheapest one to close — one query per
database before the deploy:

```sql
SELECT (SELECT count(*) FROM pg_views WHERE schemaname='public' AND viewname='stockrecord_view') view_exists,
       (SELECT count(*) FROM pg_class WHERE relname='index_stockrecord_client_created') idx_name_taken,
       (EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid='public.itemdata'::regclass AND c.contype='u'
          AND (SELECT array_agg(a.attname::text ORDER BY a.attname::text) FROM pg_attribute a
               WHERE a.attrelid=c.conrelid AND a.attnum=ANY(c.conkey)) = ARRAY['client_id','item_nr']::text[]))::text guard_verdict;
```

The misrouted MCP entries are worth fixing separately — they will silently fake shipitez coverage for
every future review.

---

## LOW

### L1 — `CREATE INDEX` without `IF NOT EXISTS`, against 5/5 sibling precedent, and unqualified

```sql
CREATE INDEX index_stockrecord_client_created ON stockrecord (client_id, created DESC);
```

Every other index-creating delta migration uses `IF NOT EXISTS`:
`V2.2.13:64` (`putaway_config_audit_scope_subject_idx`), `V2.2.25:423` (`index_adviceposition_number`),
`V2.2.30:39` and `:46` (`index_outbox_message_dispatch_lane`, `..._inflight_lane`), `V2.2.31:94`
(`idx_cancel_log_pickingorder_position`). V2.2.33 is the only one without it. Failure mode on a tenant
that already carries the name is `42P07` → V2.2.33 fails → that tenant's Flyway freezes at V2.2.32 —
the exact stall the file's header is written to avoid. I verified the name is free on the 3 databases I
can reach; it is unverified on the two shipitez PRD databases (M4).

Separately, this is the only one of the three statements that is **not schema-qualified** — statement 1
uses `public.stockrecord_view` / `public.stockrecord`, statement 3 uses `'public.itemdata'::regclass`,
this one uses bare `stockrecord`. Under a non-`public` `search_path` it resolves elsewhere or fails.
Mechanically safe today (Flyway connects with the default `search_path`), but it breaks the file's own
convention.

### L2 — The guard finds only `contype='u'`: a bare unique INDEX or a PK on the same pair fails it, and a DEFERRABLE constraint passes it while silently losing the elimination

Four edge cases in the `pg_constraint` predicate, listed with what each actually does:

| Case | Guard says | Reality | Consequence |
|---|---|---|---|
| `CREATE UNIQUE INDEX ON itemdata(client_id,item_nr)` with no constraint | **fires** | PostgreSQL's join removal reads `pg_index`, not `pg_constraint` — a bare unique index gives *both* the non-multiplication guarantee and the elimination | false positive → **frozen tenant on a correct schema** |
| `PRIMARY KEY (client_id, item_nr)` (`contype='p'`) | **fires** | same guarantees | false positive → frozen tenant |
| `UNIQUE (...) DEFERRABLE INITIALLY DEFERRED` | **passes** | the backing index has `indimmediate=false`; join removal requires an immediate unique index, so the elimination is lost while the guard is green | false negative → the perf guarantee quietly gone |
| 3-column unique, e.g. `(client_id,item_nr,x)` | **fires** | correctly — it does not guarantee pair-uniqueness | correct behaviour |

Live exposure is nil: on all 3 reachable databases both unique indexes on `itemdata` are
`constraint_backed=true immediate=true pred=false`. Matching on `pg_index` (`indisunique AND
indimmediate AND indpred IS NULL`) instead of `pg_constraint` would cover all four cases in the same
number of lines. Not fixable now — noting it so a future migration that re-states this guard does not
copy the narrower form.

Two edge cases the brief asked about that are **not** problems, stated so they are not re-raised:
`attisdropped` and `attnum <= 0` cannot occur, because dropping a column drops any constraint over it
and system columns cannot appear in a unique constraint (`dropped_cols_on_itemdata = 0` on dev
confirms the first empirically). A *partial* unique constraint is impossible — `UNIQUE` constraints
take no `WHERE` clause; only unique *indexes* can be partial, which folds into row 1 above. And the
`ORDER BY a.attname::text` collation dependency is inert for these two ASCII-lowercase names —
verified, `{client_id,item_nr}` under the dev database's collation.

### L3 — The guard runs last, after the 6.3 s / 276 MB index build

Statement order is view → index → assertion. On a tenant that fails the guard, the migration pays the
full index build and its WAL before raising, then rolls all of it back. Asserting first costs nothing
and surfaces the error immediately. Correctness is unaffected (Flyway's per-migration transaction
rolls the DDL back — confirmed: no `group`/`mixed` configured in `StartupFlywayMigrator`), so this is
cost and diagnosis latency only.

It does compound with L1 if the transaction is ever lost: a guard failure would then leave the view and
index behind, and the retry would fail on the non-idempotent `CREATE INDEX` with
`relation already exists` — pointing at the wrong defect entirely.

### L4 — `index_stockrecord_client_id` becomes a redundant prefix and is not retired

The base dump already carries `CREATE INDEX index_stockrecord_client_id ON public.stockrecord USING btree (client_id)`
(`V2.2.00:4296`). On dev_wh01_om1 it is **64 MB with 15,313 scans**, and the new
`(client_id, created DESC)` is a strict superset of it for every lookup. The table already carries 13
indexes totalling 1,299 MB against a 2,196 MB heap; this adds a 14th at 276 MB (+21%), and every
`stockrecord` insert — one per stock movement — now maintains two overlapping indexes.

Not a P1 defect: dropping the old index is a separate decision with its own risk (PostgreSQL may still
prefer the smaller one for bare `client_id` scans), and it does not belong in the migration that
creates the new one. Flagging so it is a decision rather than an oversight. Hydra PRD's `stockrecord`
is 3,373 rows / 728 kB, so the cost lands on the WineCo-scale tenants.

### L5 — `CREATE INDEX` takes a SHARE lock; the header justifies NOT CONCURRENTLY but not its cost

```
-- NOT CONCURRENTLY: CREATE INDEX CONCURRENTLY cannot run inside a transaction and Flyway wraps every
-- script in one; this repo has no precedent for Flyway's transactional-control escape.
```

Correct and well-reasoned. What it omits is the operational consequence: a non-concurrent
`CREATE INDEX` holds a `SHARE` lock, blocking **all writes to `stockrecord`** for the build — the
header's own measured 6.3 s — and, because Flyway wraps the script, for the remainder of the
migration. `stockrecord` is written by every stock movement, and this runs at application boot.

Impact today is negligible on the only PRD v2 tenant (3,373 rows). It becomes real at WineCo's
9.7 M-row scale after cutover, which is the direction this platform is heading.

### L6 — The performance figures were measured on PostgreSQL 16; production is PostgreSQL 14

`dev_wh01_om1` is `PostgreSQL 16.10`; `wh01_hydra_v2` prd is `PostgreSQL 14.23`; the test container is
`postgres:14-alpine` (`AppPostgresDBContainer.IMAGE:31`), correctly matching production. The header's
measurements — 7,356/7,647 ms, 17.9 s for the widened search, the 300–900x and ~400x figures — carry
no server version, and one sentence attributes a plan shape to production:

> `-- unfiltered "All Shippers" count over this view plans as a bare Parallel Seq Scan on stockrecord --`
> `-- byte-for-byte the plan the report has today`

I checked the structural claim on both majors and **it holds**: `EXPLAIN (COSTS OFF)` of the view body's
`count(*)` eliminates both joins on PG 16 (`Parallel Seq Scan on stockrecord sr`) and on PG 14
(`Seq Scan on stockrecord sr` — serial only because prd's table is 728 kB). So this is a
provenance/labelling issue on frozen text, not a wrong conclusion. Downgraded from Medium on that
evidence.

### L7 — `created` is nullable, and `created DESC` implies `NULLS FIRST`

`pg_attribute` on dev: `created` is **not** in `stockrecord`'s NOT NULL set (only
`id, version, activitycode, fromstoragelocation, operator, tostoragelocation, client_id` are). In
PostgreSQL `DESC` defaults to `NULLS FIRST`, so the new index orders NULLs first while the pre-existing
`index_stockrecord_created` (ASC) orders them last.

Benign for the report as built — Hibernate/SDR emits a bare `order by created desc` with no `NULLS`
clause, which matches the index. It stops matching the moment anything asks for `NULLS LAST`, and the
planner then adds the `Sort` node P3 is trying to remove. Relevant only as context for P3; no action
in P1.

### L8 — Two small test-precision nits

- **`scalar()` does not check `rs.next()`:**
  ```java
  rs.next();
  return rs.getLong(1);
  ```
  Every caller runs a `count(*)`, which always returns one row, so this cannot fire. If it ever did,
  the failure is a raw `SQLException` about cursor position rather than a readable assertion. One-line
  `assertThat(rs.next()).isTrue()`.
- **The index assertion's regex has no closing boundary:**
  `.containsPattern("\\(client_id,\\s*created")` also matches `(client_id, created_at, ...)` or
  `(client_id, created, junk)`. `stockrecord` has no other column beginning `created`, so it is
  currently exact. `\(client_id,\s*created( DESC)?\)` would pin it. Genuinely cosmetic.

---

## Explicitly NOT findings (checked, and clean)

- **SQL built by string concatenation in the fixture** — the brief asked. Every interpolated value is a
  `private static final` compile-time constant (`SHARED_SKU`, `ORPHAN_SKU`, `CLIENT_A`, the `long` ids);
  nothing reaches this from a file, a property, an environment variable or a parameter. There is no
  injection surface, and the three assertions that *do* take a value use `PreparedStatement` parameters
  (`nameFor`, and the index lookup). **Stylistic at most — I would not change it.**
- **Hard-coded ids colliding with seed data** — checked, not a risk. `db/migration` seeds exactly one
  row into `client` (`V2.2.00:2377`, id `0`) and no rows into `itemdata` or `stockrecord`. The fixture's
  `9_903_410`/`9_903_411`/`9903412` cannot collide. Nothing inserts without an explicit id, so no
  sequence is left behind the manual ids.
- **`@BeforeAll` leaking the container on failure** — JUnit 5 runs `@AfterAll` even when `@BeforeAll`
  throws, so `DB.stop()` executes; if `DB.start()` itself throws, `stop()` on an unstarted container is
  a no-op, and Ryuk reaps regardless. `ReplenishmentMonitorViewSchemaIT:96` uses the identical shape.
- **Positive controls being vacuous** — they are not. Both assert `isEqualTo(1L)` against a query that
  measures exactly the fixture property the following assertion depends on (a SKU string held by two
  `client_id`s; a `stockrecord` row with no resolving `itemdata`). If the fixture stopped having the
  shape, the control reds before the assertion, which is the correct order.
- **`version` / `entity_lock` in the projection** — the brief asked whether this is a hazard for P2.
  The header's instruction is right and the repo already follows it: `AbstractBaseEntity` is a
  `@MappedSuperclass` carrying `@Version private Integer version` (`AbstractBaseEntity.java:15,34-35`),
  and **neither existing view entity extends it** — `StockView` and `ReplenishmentMonitorView` are both
  bare `@Entity @Table(name=...)`. So the trap is real but the precedent is correct, and the column is
  needed for the "strict superset" shape. **No change in P1**; P2 should not extend `AbstractBaseEntity`
  and, since SDR will expose the repository, should consider `@Immutable` plus a withdrawal of the
  write verbs so a `PUT`/`PATCH` returns 405 rather than a PostgreSQL error.
- **No `GRANT` on the new view** — correct. There is no `GRANT` precedent anywhere in `db/migration`
  (the only hit is a comment in `V2.2.21:68`), and Flyway connects as the object owner
  (`current_user = wh01_hydra_v2_app`, which also owns `stockrecord` and `stock_view` on prd).
- **`regclass` resolution failing** — `'public.itemdata'::regclass` raises `42P01` before the guard's
  own message if the table is absent. Every v2 tenant has `itemdata`; the resulting error is still a
  clear migration failure, just with a less helpful message.
- **Guard comparison failing open** — checked the NULL path. If `array_agg` returned NULL the
  comparison yields NULL, the row is not selected, `NOT EXISTS` is true and the migration **raises**.
  It fails closed, which is the safe direction.
- **Known-open items** — the P3 "`Sort` node is gone" acceptance and the absence of a verify script
  were excluded by the brief and are not re-reported.

---

## Completeness statements and blind spots

- **"Every other index-creating delta migration uses `IF NOT EXISTS`"** (L1) — derived by
  `grep -rn "CREATE INDEX\|CREATE UNIQUE INDEX" src/main/resources/db/migration/*.sql` excluding the
  `V2.2.00` base dump, then reading each of the 5 hits. Blind spot: an index created inside a `DO` block
  or an `EXECUTE` string would not be matched by that grep (`V2.2.20` has such a block, but it manages
  pre-existing indexes rather than creating one).
- **"`V2.2.33` is free"** (§0) — derived by `git ls-tree` over all 309 `refs/remotes/origin/*` after
  `git fetch --all`, with a positive control on `V2\.2\.3` that returns the known `V2.2.30/31/32` across
  many branches, so a silent zero is excluded. Blind spot: a branch pushed after that fetch; per the
  repo's own rule the sweep must be re-run immediately before merge.
- **"the view does not exist on any tenant"** (M4) — I reached 3 distinct databases
  (`dev_wh01_om1`, `wh01_hydra_v2` prd, `wh01_hydra_v2` uat). `wh01_shipitez_v2` and `wh02_shipitez_v2`
  are unreachable from this lane because both shipitez MCP entries resolve to Hydra's database. The
  landlord roster query above is the complete tenant set for PRD; UAT and any non-PRD landlord were not
  enumerated.
- **The column-superset check** (§0) was run against `dev_wh01_om1`, which is at Flyway head `2.2.32` —
  the same head as both Hydra databases — so it reflects the schema V2.2.33 will actually land on. It
  does not cover a drifted tenant, which is the case the header itself says nothing detects.
- **I did not run the test suite.** Compilation, the 4/4 green claim and the full-suite baseline are the
  verifier lane's instrument, not this one. Every claim above is from reading the two files, reading
  their siblings in the repo, and read-only queries against live databases. No file in the worktree was
  modified; no `git checkout`/`restore`/`stash` was run.
