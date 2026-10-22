# Lane I — SBDEV-3363 Fix D (AC-4) review: `V2.2.31` + population

**Tree (only tree read):** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3363-ac4`
**Commit:** `2ae9e9a7` · branch `bugfix/SBDEV-3363-cancellation-log-pickline-key` · base `origin/develop` `9e294d4b`
**Plan:** `sbdocs/1-Projects/wms2/plan/SBDEV-3363-deferred-cancel-terminal-path.md` §3.4
**Reviewer:** lane I (`review-3363-ac4`) · 2026-09-15
**Verdict:** the change itself is sound and I found no correctness defect in the SQL, the mapping,
the population or the tests. **One High**, against the *risk model* stated in the commit message
rather than against the code; one Medium (stale sibling comments the same branch falsifies);
four Lows.

---

## Findings

### H1 — High. The commit's stated deploy-safety mechanism does not exist: production runs `ddl-auto=none`, not `validate`

The commit message rests its estate argument on this sentence:

> "That matters because the column is MAPPED — Hibernate ddl-auto=validate fails on a
> missing mapped column, so a stalled tenant would have broken its EMF."

**That is false for this application.** `src/main/resources/application.properties`:

```
103  # dont use with data you care about drops tables! spring.jpa.hibernate.ddl-auto=create
104  #spring.jpa.hibernate.ddl-auto=validate
105  spring.jpa.hibernate.ddl-auto=none
```

`validate` is the commented-out line. Second instrument, in this same repo, written for exactly this
reason — `src/main/resources/db/verify-tenant-schema-conformance.sh:7`:

> "SBDEV-3295. Nothing checks this anywhere. **Production runs `spring.jpa.hibernate.ddl-auto=none`**
> (application.properties), so there is no boot-time validation"

Nothing in `Dockerfile`, `.gitlab-ci.yml` or `.github/` overrides it (grepped for `ddl-auto` /
`DDL_AUTO`; only the two test-resource files set anything, `validate` and `create-drop`).

**Why it matters — the failure inverts from loud to silent.** Under `validate`, a tenant missing the
column fails at EMF creation: loud, at boot, before traffic. Under `none` there is no schema check at
all. The tenant boots healthy, serves normally, and then the *first cancellation* on it issues an
INSERT naming a column the table does not have. Demonstrated on `postgres:14-alpine` (positive
control: the `CREATE TABLE` and `BEGIN` on the same connection succeeded):

```
BEGIN
ERROR:  column "pickingorder_position_id" of relation "cl" does not exist
ERROR:  current transaction is aborted, commands ignored until end of transaction block
ROLLBACK
```

`recordCancellation` is `Propagation.MANDATORY` and runs inside the caller's cancel transaction, so
that `42703` → `25P02` sequence **rolls back the caller's cancel** — which is precisely the outcome
the migration header spends twenty-five lines refusing to accept for a UNIQUE index. The change
closes that door and leaves this one open, and the commit message says the opposite.

**The paths by which a tenant could run this code without the column are not hypothetical.** Each of
these is cited from this repo:

| Path | Evidence |
|---|---|
| A tenant stalls at an earlier version and the app keeps serving | `StartupFlywayMigrator` logs and continues per tenant (`:310`–`:374`), and `StartupFlywayMigrationRunner:75-79` catches at the boot boundary: *"Contract: migrations never take the app down."* |
| …and this has actually happened in production | `db/migration/README.md`: `V2.2.07` failed on `wh01_hydra_v2` on 2026-08-05 over object-ownership drift and *"that **one** non-owned object freezes the whole tenant at its current version"*. That is the only v2 PRD tenant. |
| `APP_FLYWAY_MIGRATE_ON_STARTUP=false` | `db/landlord-migration/README.md:159` — row 4, *"`APP_FLYWAY_MIGRATE_ON_STARTUP` not `false` in the deployment — **outstanding** — check UAT + prd"*. In-repo, this is recorded as **not verified**. |
| A tenant DB with no `flyway_schema_history` | `db/migration/README.md`: *"never auto-baselined — it is skipped with an error log until repaired"*. |
| A tenant onboarded after the 2026-09-15 estate check | unmeasurable by construction. |

**This does not block the code.** It blocks the conclusion that the estate check is sufficient
mitigation. Two concrete asks:

1. Correct the sentence in the commit message (and the corresponding reasoning wherever the PR body
   repeats it) — the accurate statement is *"production is `ddl-auto=none`, so a tenant that misses
   this migration fails at the first cancel, not at boot."*
2. Add a post-deploy verification row rather than relying on boot to complain. The right instrument
   already exists and needs no edit: `src/main/resources/db/verify-tenant-schema-conformance.sh`
   derives its reference by replaying `db/migration` into a throwaway container, so it picks up
   `V2.2.31` automatically and reports `MISSING_COLUMN` as an ERROR. Run it per tenant after the
   deploy. (A bare `SELECT` on `information_schema.columns` per tenant is the cheap version.)

### M1 — Medium. Two sibling comments on this branch now assert the opposite of what this branch does

Both say the table has no pick-line column. Both are false as of `2ae9e9a7`, and neither was touched
by it.

`src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java:618`:

> `// customerorder_cancellation_log has no pick-line column, and SBDEV-3316's completeReversal`
> `// moves stock per row filtered on customerorder_position_id alone`
> … `// the row end needs a pickingorder_position_id column, i.e. a migration; that is split out.`

`src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java:2857`:

> `* <em>row</em>, and that is deliberate: {@code customerorder_cancellation_log} has no`
> `* pick-line column, and keying on {@code customerorder_position_id} would be wrong`

This is not cosmetic. `PickingorderBusinessService:605-640` is the canonical explanation of why the
SBDEV-3332 duplicate-row defect was closed with an entry guard instead of a row constraint — it is
the first thing a reader chasing that defect will find, and after this commit it will tell them a
column exists nowhere while `grep` shows it three files away. Suggested edit, both sites: keep the
reasoning, change the tense — *"the column exists as of `V2.2.31` (SBDEV-3363 AC-4); the uniqueness
constraint on it is still deferred until `recordCancellation` is idempotent."*

### L1 — Low. The violation is synchronous at `save()`, not "at flush"; and that changes what the deferred step 2 must do

`CustomerorderCancellationLog.java:18-20`:

```java
@Id
@GeneratedValue(strategy = GenerationType.IDENTITY)
private Long id;
```

With `IDENTITY`, Hibernate must execute the INSERT to obtain the key, so `logRepository.save(log)`
issues it immediately. The header's *"a `DataIntegrityViolationException` **at flush**"* is imprecise;
the conclusion is unchanged and if anything stronger (it throws inside `recordCancellation`).

The reason to record it: PostgreSQL aborts the whole transaction on any error (shown in H1's
`25P02`), so **a `try/catch` around `save()` cannot rescue the caller's cancel** once the index is
UNIQUE. The plan's prescription for step 2 — *"look up and skip/update rather than insert"* — is the
right shape and dodges this. But lookup-then-insert is TOCTOU, so if step 3 ever lands, the race
still rolls back a cancel. Step 2's acceptance criteria should name a SAVEPOINT (`REQUIRES_NEW` /
nested transaction) or `ON CONFLICT DO NOTHING` for the concurrent arm, not just the lookup.

### L2 — Low. No FK to `pickingorder_position`, one migration after `V2.2.28` added one to this very table — and the reason is not stated

`V2.2.28`, on the same table, in the same ticket family, exists precisely because a bigint id column
with no FK let *"an id from the wrong table persist cleanly and nothing complained."* `V2.2.31` adds
another bigint id column with no FK and does not say why. A reader arriving from `V2.2.28` will
assume it was forgotten.

It was not wrong to omit it: `pickingorder_position` rows are genuinely deleted —
`CustomerorderService.checkAndCleanUpPickingOrderPositions` (`CustomerorderService.java:367`,
`pickingorderPositionRepository.delete(position);`) removes pick lines on a picking-date change — so
an FK would either block that or need `ON DELETE SET NULL`. Two asks, both one paragraph:

- say so in the header, so the next reader does not re-derive it;
- note the consequence it creates — **the new column can dangle.** A log row written for a pick line
  that is later deleted by the picking-date cleanup points at an id with no parent. Ids come from
  `seqentities` and are never recycled, so the value stays unambiguous and the planned UNIQUE key is
  unaffected; but anything that *joins* on this column must be an outer join.

### L3 — Low. `CancellationLogEntryDto` does not expose the new column, and it is the one surface that needs it

`src/main/java/net/aim_ai/wms/json/CancellationLogEntryDto.java` carries `customerorderPositionId`
and no pick-line id. It is what `CancellationReversalService.detail()` renders to the mobile reversal
screen (`controller/mobile/OrderCancellationController`). For the 41 measured CO positions that own
more than one pick line, two log rows now reach the operator with the same
`customerorderPositionId`, the same SKU and the same amount, and nothing distinguishing them.

Pre-existing, not introduced here, and correctly out of this commit's scope — but this commit is what
makes it fixable, so it belongs next to §10 F4 rather than being lost.

### L4 — Low. The IT is version-pinned, so it cannot see step 3 landing before step 2

`CancellationLogPickingorderPositionIdIT` migrates to `MIGRATION_UNDER_TEST = "2.2.31"` in every test,
so a later `V2.2.32` that makes the index UNIQUE would leave all three tests green. That is correct
scoping for a schema IT — but it means the "uniqueness stays deferred until `recordCancellation` is
idempotent" contract, which the commit, the header and the test javadoc all lean on, has no rail that
would fire if the ordering were violated. One line in step 2's AC ("the rail that pins the ordering
is X") is enough; no change needed here.

---

## Clean verdicts — claims I probed and found true

1. **The migration is idempotent and re-runnable, and safe on a populated table.** Ran it twice with
   `psql -v ON_ERROR_STOP=1` against `postgres:14-alpine`, on a table built from `V2.2.00`'s DDL and
   seeded with 24 rows (the measured estate population). Second pass: `NOTICE: column … already
   exists, skipping` / `NOTICE: relation … already exists, skipping`, no error. Nullable `bigint`
   with no default, so `ADD COLUMN` is catalog-only — no table rewrite. All 24 rows end NULL.
2. **The `COMMENT ON COLUMN` syntax is valid** — I did not take this on reasoning, I ran it. The
   implicit concatenation is legal (PostgreSQL joins string constants separated by whitespace
   containing at least one newline, which each fragment here is), and `''` renders correctly;
   `col_description()` returns the full sentence with `caller's` intact.
3. **The partial-index predicate matches what the code writes.** Catalog `indexdef`:
   `CREATE INDEX idx_cancel_log_pickingorder_position ON public.customerorder_cancellation_log USING
   btree (pickingorder_position_id) WHERE (pickingorder_position_id IS NOT NULL)`. Every row the
   service writes carries a non-null value (see 5), so every new row is indexed and only the legacy
   rows are exempt — exactly what the header claims.
4. **The non-uniqueness argument is correct.** Verified against the code, not the prose:
   `CancellationLogService.java:38` is
   `@Transactional(value = "tenantTransactionManager", propagation = Propagation.MANDATORY)`; the
   method's only write is `return logRepository.save(log);` on a freshly constructed entity — no
   dedup, no existence check, no `ON CONFLICT`; and all three call sites
   (`CustomerorderPositionService:143`, `CustomerorderService:424`,
   `PickingorderBusinessService:544`) invoke it from inside their own `@Transactional` cancel
   methods. So a unique violation would abort the caller's cancel. **Empirically confirmed**: with
   the index mutated to `CREATE UNIQUE INDEX`, the IT errors with
   `duplicate key value violates unique constraint "idx_cancel_log_pickingorder_position"`.
5. **The population is null-safe, and `getId()` is non-null at every call site.**
   `pickingPosition.getState()` is dereferenced unguarded at `CancellationLogService.java:46`,
   fifteen lines above the new line, so the comment's claim holds. All three call sites iterate the
   result of `pickingorderPositionRepository.findByCustomerorderpositionId(...)` — managed entities
   loaded from the database. No call site constructs a `PickingorderPosition`, so a transient entity
   with a null id cannot reach it.
6. **The tests are not vacuous — mutation-checked independently, in a `/tmp` copy; the worktree was
   never modified.**
   - unmutated, re-run in this tree: `CancellationLogServiceUnitTest` **7/7 green**;
     `CancellationLogPickingorderPositionIdIT` **3/3 green** (8.8 s, real container).
   - deleting `log.setPickingorderPositionId(pickingPosition.getId());` →
     `Tests run: 7, Failures: 1`, `recordCancellationRecordsPickingorderPositionId` red.
   - `CREATE INDEX` → `CREATE UNIQUE INDEX` → **two** of three IT tests red
     (`partialIndexIsCreated` on the `doesNotContain("UNIQUE")` assertion, and
     `duplicatePickLineRowsAreAcceptedForNow` on the insert). The deferred-uniqueness contract is
     genuinely pinned.
   - the pre-fix/post-fix arrangement is real: each test migrates to `2.2.30` and asserts the column
     and index are **absent** before migrating to `2.2.31`, so deleting the migration cannot leave a
     green.
7. **`SET session_replication_role = replica` is sound and does not leak.** It is a per-session GUC;
   `insertLogRow` opens and closes its own `Connection` for each insert, so it never outlives the
   statement; and each test runs against its own `CREATE DATABASE`-d database. It requires
   superuser, which the Testcontainers user is. Using it to skip the parent chain is the right call
   here — the test is about the index, and a dozen rows of fixture would assert nothing.
8. **The `pickedPosition()` fixture change is safe for the other six tests.**
   `AbstractBaseEntity.setId` is a plain setter with no cross-field side effect. The only
   id-sensitive behaviour on the class is `equals`/`hashCode`, and no test in that class puts a
   `PickingorderPosition` into a collection or compares two of them; the Mockito stubs key on longs,
   not on the entity. `60999L` collides with none of the other fixture constants (60938, 60941,
   60864, 60861, 17662, 777). 7/7 green confirms.
9. **The estate check reproduces.** Queried all six tenant DBs directly, independently of the
   author's check — every one at `2.2.30`, `0` failed migrations, column absent:
   `wms2-hydra` (PRD), `wms2-wineco-dev`, `c1wh-shipitez-uat`, `nywh-hydra-uat`, `nywh-shipitez-uat`,
   `wsl-wineco-uat`. Log-row counts match the header (wineco-dev 8, hydra PRD 16, UATs 0).
10. **The "41 CO positions own more than one pick line" claim reproduces exactly** on
    `c1wh-shipitez-uat`: `1 → 264,198`, `2 → 39`, `3 → 1`, `4 → 1` (39+1+1 = 41 of 264,239). The
    architectural conclusion drawn from it — key on `pickingorder_position_id` alone, never on
    `customerorder_position_id`, and never the composite — follows, and
    `pickingorder_position.customerorderposition_id` is indeed a single column
    (`PickingorderPosition.java:32`), so the functional-dependency argument holds.
11. **No Flyway version collision.** Swept all 13 remote refs on a freshly fetched `origin`
    (`git ls-tree` per ref over `db/migration`): every one tops out at `V2.2.30`; nobody else claims
    `V2.2.31`. ⚠ Re-run immediately before merge — a branch pushed after this sweep can still take it.
12. **Rolling deploy / replica-before-Flyway is genuinely closed.** This is the one sub-question of
    the deploy-risk item that is safe by design: `StartupFlywayMigrationRunner` is an
    `ApplicationRunner`, and (`:22-24`) *"ApplicationRunner beans complete before
    `ApplicationReadyEvent`, which is what flips the readiness probe — so replicas do not take
    traffic mid-migration"*. The other direction is safe too: old pods still serving during the
    rollout are unaffected by an extra nullable column they do not map.
13. **No other writer, and nothing else needs the column.** `recordCancellation` is the only insert
    into `customerorder_cancellation_log` in `src/main` — no native `INSERT`/`UPDATE` against the
    table anywhere, and `CancellationReversalService` only loads rows and updates `reversal_*`
    fields on the same mapped entity (so its UPDATEs carry the column through unchanged, including
    NULL on legacy rows).
14. **`V2.2.00` needs no change for fresh installs.** It creates the table without the column; a new
    tenant replays the whole `db/migration` set including `V2.2.31`, so the column arrives. Editing
    the applied baseline would break checksums on every existing tenant and must not be done.
15. **Plan conformance: exact.** §3.4 specifies nullable, partial, non-unique, keyed on
    `pickingorder_position_id` alone, populated in `recordCancellation`, with uniqueness split into a
    follow-up. The commit implements each point, including the composite-key rebuttal.
16. **No doc drift.** Only two files under `sbdocs/3-Resources/` mention the table
    (`reports/260527-wms-v1-v2-db-migration-script-comparison.md`,
    `reports/260526-utc-migration-code-changes-reference.md`), both historical migration-comparison
    reports that do not enumerate this table's columns. No architecture, design or data-dictionary
    doc describes it, so nothing needs updating.

---

## Notes on instruments (for whoever re-runs this)

- `mvn ... -DskipTests=true failsafe:integration-test` **skips failsafe as well** and prints
  `Tests are skipped` / `BUILD SUCCESS`, while the previous run's XML sits in
  `target/failsafe-reports/` looking like a result. I hit this first; the correct invocation is
  `mvn -o -Dsurefire.skip=true test-compile failsafe:integration-test -Dit.test=<Class>
  -Dfailsafe.failIfNoSpecifiedTests=false`.
- `failsafe:integration-test` **alone** reports `BUILD SUCCESS` even with failures — only
  `failsafe:verify` fails the build. Read the `Tests run:` line, not the build result. (Both mutation
  runs above printed `BUILD SUCCESS` with reds in them.)
- The tenant DB MCP connections drop the first query after an idle period; every one of them needed
  exactly one retry.
- The author's full `mvn clean verify` (surefire `6630/0/0/1`, failsafe `412/0/0/31`) is corroborated
  by `target/failsafe-reports/failsafe-summary.xml` in this tree — `completed=412 errors=0
  failures=0 skipped=31`.
- The `postgres-integration` lane runs `ddl-auto=validate` against a container built from
  `db/migration` (`src/test/resources/application-postgres-integration.properties:163`), so it is the
  CI net that would catch an entity/migration mismatch of this kind. It was green in the author's
  full verify, which is consistent with the entity and the migration agreeing.
