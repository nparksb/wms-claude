# SBDEV-3154 — migration-safety adversarial review of `V2.2.23__seed_admin_action_console_functions.sql`

**Lane:** migration safety (adversarial, pre-write). **Date:** 2026-09-01.
**Target:** `/home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-3154-admin-action-console-gating.md` §2.
**Repo:** `/home/nampark/dev/wms-claude/v2/wms2-api` @ `origin/develop` = `2e9ddcfa`.
**Method:** read-only. `git show origin/develop:<path>` for all code/SQL; live SQL against all six v2
tenant DBs via MCP. No maven, no worktree, no file edits outside this evidence directory.

The migration as §2 describes it will **not** wedge a Flyway chain and **is** re-runnable. Every
attack on the SQL itself failed, and I record the failures below so nobody re-spends the budget on
them. The real defects are elsewhere: one missing code change that makes the feature permanently
dead on any future tenant, one cheap instrument the plan wrongly declares nonexistent, and no
revert path.

---

## Fleet measurement (all six tenants, 2026-09-01)

One combined probe, run per tenant. Full SQL at the foot of this file.

| probe | wineco-dev | hydra PRD | wsl-wineco UAT | nywh-hydra UAT | c1wh-shipitez UAT | nywh-shipitez UAT |
|---|---|---|---|---|---|---|
| `mywms_function` PK | 1 | 1 | 1 | 1 | 1 | 1 |
| `mywms_function` UNIQUE | 1 | 1 | 1 | 1 | 1 | 1 |
| `mywms_role_mywms_function` PK/UNIQUE | **1** | **1** | **1** | **1** | **1** | **1** |
| `mywms_role` UNIQUE(name) | 1 | 1 | 1 | 1 | 1 | 1 |
| `mywms_function` rows | 82 | 82 | 82 | 82 | 82 | 82 |
| `max(mywms_function.id)` | 30,704,227 | 132,923 | 34,421,425 | 3,331,573 | 5,565,804 | 926,408 |
| rows with `name IS NULL` | 0 | 0 | 0 | 0 | 0 | 0 |
| rows where `number`/`name` ≠ `function` | 0 | 0 | 0 | 0 | 0 | 0 |
| case/whitespace variants of either new constant | none | none | none | none | none | none |
| rows where `function <> btrim(function)` | 0 | 0 | 0 | 0 | 0 | 0 |
| rows matching `lower(btrim(name))='super-admin'` | 1 (`51806`) | 1 (`585`) | 1 (`51806`) | 1 (`50356`) | 1 (`50406`) | 1 (`585`) |
| `mywms_role` rows with exactly `name='super-admin'` | 1 | 1 | 1 | 1 | 1 | 1 |
| `client` row with `id=0` | 1 | 1 | 1 | 1 | 1 | 1 |
| `max(version)` in `flyway_schema_history` | 2.2.22 | 2.2.21 | 2.2.21 | 2.2.21 | 2.2.21 | 2.2.21 |
| rows with `success = false` | none | none | none | none | none | none |
| PostgreSQL | 16.10 | 14.23 | 16.10 | 16.10 | 16.10 | 16.10 |

The plan's own `db_verification_note` reproduces correctly against this: 82 rows everywhere, both
constants absent everywhere, `super-admin` present everywhere, `max(id)` spanning 132,923 →
34,421,425. That part of the plan is sound.

---

## Critical

### C1 · `UtilRestController.initDB` is not in scope, so every future tenant gets four permanently dead routes

The plan's §3 "Code changes" enumerates exactly two files: `WmsConstants.FunctionEnum` and
`AdminActionController`. It never mentions `UtilRestController`. That omission is the same defect
V2.2.19 was written to warn about, in the file the plan names as its template:

`src/main/resources/db/migration/V2.2.19__seed_web_view_function_grants.sql`, STEP 5:

> 🔴 super-admin is MANDATORY. `initDB` enumerates super-admin's 81 grants one line at a time, so a
> new constant reaches nobody by default.

Measured on `origin/develop`: `grep -c "role_super_admin.getId()"` over
`src/main/java/net/aim_ai/wms/controller/rest/UtilRestController.java` = **77** individually written
grant lines, the last three being the `WEB_UI_ACTION_*` constants at :413–:416, plus a
`grantFunction(...)` helper block below them. `AccessService.updateFunctionList()`
(`src/main/java/net/aim_ai/wms/service/AccessService.java:64`) reflects over `FunctionEnum` and
creates the **`mywms_function` row**, but grants nothing:

```java
if (!functionList.contains(value))
    userFunctionService.createEntity(value);
```

So on a tenant provisioned the fresh way:

1. `db/migration` runs. `V2.2.23`'s two function INSERTs land. Its grant statement joins
   `mywms_role` on `name='super-admin'` — and the base dump **does** seed that role
   (`V2.2.00__base_v2_schema.sql:2880`, id 585), so the grant lands too. Good so far.
2. `initDB` then runs `createEntity("super-admin")`
   (`UtilRestController.java:245`) — a **new** role row, and enumerates 77 grants that do not
   include either new constant.

Result on that tenant: `WEB_UI_ACTION_RECOVER_STUCK_PALLETS` and
`WEB_UI_ACTION_SYSTEM_MANAGEMENT` exist as rows, are held by the base dump's `super-admin` (id 585)
if it survives, and are **not** held by the `super-admin` that `initDB` created and that real users
are actually grouped into. All four routes then 403 for every user on that tenant, forever, with no
menu change to signal it.

The repo already treats this two-surface parity as a rule with its own test.
`src/test/java/net/aim_ai/wms/unit/controller/rest/UtilRestControllerSeedUnitTest.java`, test
`C-8d`:

> Two independent seeding surfaces write the same policy: `initDB` for a freshly-initialised DB and
> V2.2.21 for already-provisioned tenants. Nothing cross-checked them, so a constant added to one
> and not the other would produce a fleet where a tenant's capabilities depend on how it was
> created — and only the Java half had a test.

And the immediate precedent for adding a *new* constant — `WEB_UI_VIEW_PARCEL_PICKING` in
SBDEV-2967-B — shipped **three** things, not two: the constant, the migration, and the `initDB`
grant line, pinned by `declaresTheParcelPickingViewConstant` at
`UtilRestControllerSeedUnitTest.java:264` which ends:

```java
runInitDB();
assertThat(grants.getOrDefault("WEB_UI_VIEW_PARCEL_PICKING", Set.of()))
        .contains("super-admin", "inventory-manager", "outbound-manager");
```

**Nothing in the current suite catches this for a new constant.** The only two tests that reflect
over `FunctionEnum` are `FunctionGuardArchTest:165` (`declaredFunctionConstants()`, used for
annotation-value validation, not grants) and the hard-coded `getDeclaredField(
"WEB_UI_VIEW_PARCEL_PICKING")` above. There is no "every constant has a super-admin grant" test.

**Fix:** add two `accessService.addFunctionToRole(...)` lines (or two `grantFunction(...)` calls) for
the new constants against `role_super_admin` in `initDB`, and one assertion in
`UtilRestControllerSeedUnitTest` mirroring `C-8d`'s parity check for `V2.2.23`. This is one file and
about six lines, and it belongs in §3 and in AC-1.

---

## High

### H1 · "Nothing executes the migration" is false — eight `*IntegrationTest` classes already run the whole `db/migration` chain

Plan §4.3:

> **Nothing executes the migration.** No test in this repo runs `V2.2.23` against a database, so a
> 23502 or a same-id double insert would not be caught by a green suite. AC-3's per-tenant query is
> the only instrument.

`git grep -n "classpath:db/migration" origin/develop -- src/test` returns eight classes that call
`Flyway.configure().dataSource(...).locations("classpath:db/migration").load().migrate()` against a
Testcontainers Postgres:

| class | line |
|---|---|
| `integration/PickingStartedGuardScalarSubqueryIntegrationTest.java` | 133 |
| `integration/StartupFlywayMigratorIntegrationTest.java` | 169 |
| `integration/StockHistoryClientIsolationIntegrationTest.java` | 132 |
| `integration/TransactionDetailAllowListStructuralIntegrationTest.java` | 81 |
| `integration/TransactionDetailNullAmountIntegrationTest.java` | 93 |
| `integration/TransactionDetailUlPickIntegrationTest.java` | 110 |
| `integration/query/ReplenishMonitorVisibilityIntegrationTest.java` | 66 |
| `integration/repository/RefillFixedLocationPredicateIntegrationTest.java` | 205 |

These are in the **failsafe** lane, not surefire — `pom.xml:518-521` excludes
`**/*IntegrationTest.java` from surefire and `pom.xml:663-666` includes it in failsafe — so they run
under `mvn verify`, not `mvn test`. (The pom's SBDEV-3091 warning about classes running in neither
lane applies to `*IT.java`, a different suffix.)

That chain starts at `V2.2.00__base_v2_schema.sql`, which seeds real data:
`client` id 0 = System-Client (:2377), 80 `mywms_function` rows (ids 500–579, :2738), and ten
`mywms_role` rows including `super-admin` id 585 (:2880). So a fresh Testcontainers DB satisfies
every precondition `V2.2.23` needs, and the migration is exercised end-to-end today, for free, on
every `mvn verify`.

What that instrument would actually catch, which AC-3 cannot catch before merge:

- a 23502 not-null violation from a short column list;
- a 23503 FK violation on `client_id`;
- a same-id double insert — `mywms_function_pkey PRIMARY KEY (id)` is in the base dump at :3420, so
  this is a hard 23505 on a fresh DB;
- the guard/grant key asymmetry in H3;
- a missing or misspelled `super-admin` grant, asserted as a row count of 2.

Six assertions against `mywms_function` and `mywms_role_mywms_function` in one new
`*IntegrationTest` (or appended to an existing one's `@BeforeAll`-migrated DB) turn the plan's
"no instrument exists" into a pre-merge red. I did not run the lane — this lane is read-only and
needs Docker — so treat "the failsafe lane is currently green" as unverified here; the plan should
measure the baseline before adding to it.

**Fix:** delete the §4.3 bullet, and add an acceptance criterion for a migration IT.

### H2 · There is no revert path, and the obvious revert freezes the chain

The plan has no §on rollback. The answer is that **the file becomes irreversible the moment it
applies anywhere**, and the naive revert is actively destructive:

`StartupFlywayMigrator.java:39-40`:

```
 * stop, not a silent skip: {@code validateOnMigrate} is on and the default
 * {@code ignoreMigrationPatterns} is {@code *:future}, which does not cover an unapplied lower version,
```

`*:future` covers a version in the DB that is *higher* than anything resolved locally. It does not
cover an applied migration whose script has been **deleted**. So deleting
`V2.2.23__...sql` after dev has applied it makes `migrate()` throw `FlywayValidateException` on
every subsequent boot, and per the same class that freezes that tenant's whole chain silently —
tenant failures never abort boot, and probe `O` shows no `success=false` row is ever written to
record it (Hydra PRD's documented 12-day, nine-migration freeze left **zero** failed rows in
`flyway_schema_history`, which I confirmed: `flyway_failed = none` on all six).

The only safe revert is a **forward** `V2.2.24` that deletes the grant rows first and then the two
`mywms_function` rows (in that order — `fkgewu6gt6lnpo19dlhqmtkrhgs` FKs
`mywms_role_mywms_function.functionlist_id` to `mywms_function(id)`, base dump :5290), plus removing
the four `@RequiresFunction` annotations. Worth two sentences in the plan so the on-call answer is
not invented under pressure.

### H3 · The guard keys on `function`; the grant keys on `name`. A row matching one but not the other silently grants nothing

Both precedents have this asymmetry and the plan inherits it. V2.2.19 STEP 1 guards on the unique
column, for a reason it states explicitly:

```sql
WHERE NOT EXISTS (
    SELECT 1 FROM mywms_function WHERE function = 'WEB_UI_VIEW_PARCEL_PICKING'
);
```

> Guard on `function`, NOT on `name`: the UNIQUE index is on `function` … guarding the non-unique
> column would be correct only by accident.

Then STEP 5 grants by joining on the very column it just called unreliable:

```sql
JOIN mywms_function f ON f.name = 'WEB_UI_VIEW_PARCEL_PICKING'
```

If a tenant ever holds a row with `function = 'WEB_UI_ACTION_SYSTEM_MANAGEMENT'` and a different or
NULL `name`, the guard correctly skips the insert **and** the grant finds nothing — the migration
reports success and the function has no holder. Since `name` is nullable and carries no unique
index, the converse is also open: two rows sharing that `name` would produce two grant rows.

Today this is latent, not live: probes `G`, `H`, `I` and `J` are all 0/none on all six tenants, so
`number = function = name` holds with zero exceptions fleet-wide. But the fix costs one word — key
the grant's join on `f.function` instead of `f.name` — and it makes the guard and the grant agree on
the same column, which is the actual invariant.

**Fix:** `JOIN mywms_function f ON f.function IN ('WEB_UI_ACTION_RECOVER_STUCK_PALLETS',
'WEB_UI_ACTION_SYSTEM_MANAGEMENT')`, and say in the header why it is `function` and not `name`.

---

## Medium

### M1 · §2.1's constraint-shape rationale is stale, and it conflates two tables

Plan §2.1, on why two statements are needed:

> On a tenant that has the PK that is a 23505 abort; on a tenant missing it (production
> `wh01_hydra_v2` has neither a PK nor a unique index on the join table — recorded in V2.2.21) it
> inserts **silently** and leaves two rows sharing an id.

Two errors, both correctable without changing the SQL:

1. **Wrong table.** The rows in question go into `mywms_function`, which has carried
   `mywms_function_pkey PRIMARY KEY (id)` (base dump :3420) and
   `uk_hxqe1tp0v5sk4le8ij6wmtrq1 UNIQUE (function)` (:3700) since V2.2.00. Measured: both present on
   all six tenants (probes `A`, `B` = 1). The join table's constraint shape is irrelevant to a
   double insert into `mywms_function`. **The "silent double insert" the plan warns about cannot
   happen on any tenant in the estate** — it would be a clean 23505 that aborts the file. Still a
   reason to write two statements, just a different reason, and the difference matters because a
   23505 is *visible* while a silent duplicate is not.

2. **Stale fleet fact.** `V2.2.20__authorization_join_table_primary_keys.sql` (SBDEV-3010) landed
   after V2.2.19 and V2.2.21 were written, and it gives `mywms_role_mywms_function` a primary key
   under a name-agnostic promote-or-create algorithm. Probe `C` = 1 on **all six tenants including
   Hydra PRD**, and probe `P` shows `2.2.20(r21)` applied everywhere. The three-shapes-in-the-fleet
   claim, and specifically "none at all on PRD", describes the estate as it was on 2026-08-22 and is
   no longer true.

`WHERE NOT EXISTS` remains the right choice — constraint **names** still drift (`_pkey` vs `_pk`),
so `ON CONFLICT ON CONSTRAINT <name>` would still break, and `WHERE NOT EXISTS` is what makes the
file re-runnable. Only the justification needs rewriting.

### M2 · §2.3's out-of-order framing is a misdiagnosis; out-of-order is not engaged by this deploy

Plan §2.3:

> **Only dev is at `2.2.22`. All five other tenants are at `2.2.21`.** So `V2.2.23` will land on five
> databases that still owe `V2.2.22`. `app.flyway.out-of-order=true` handles a lower version
> arriving after a higher one, so this is safe.

The five tenants owe `2.2.22` because they have not been *deployed* since it merged, not because the
image lacks it. `V2.2.22__seed_order_batch_update_priority_sysprops.sql` is on `origin/develop`
already, so any image carrying `V2.2.23` also carries `V2.2.22`, and `migrate()` applies pending
migrations in **ascending version order** in one run: 2.2.22 then 2.2.23. Nothing arrives out of
order. AC-3's instruction to check for both versions per tenant is right, but the reason given is
not the reason.

The claim it displaces is the one that actually matters: the real out-of-order exposure is a
**lower** version merging *after* `V2.2.23` has been applied — someone else's `V2.2.22`-or-below
branch landing next week. That is what AC-6's collision re-check exists for, and it is a *collision*
risk, not an out-of-order risk, per
`src/main/resources/db/check-migration-version-collision.sh:15-18`:

> `app.flyway.out-of-order=true` handles the LATE-MERGE case … It does NOT handle a COLLISION — two
> different files claiming the same version is unrecoverable without renaming one, and renaming
> after a database has applied it is worse.

The plan's underlying safety claim does hold, and I verified the mechanism rather than trusting it:

- `app.flyway.out-of-order=true` is set at `src/main/resources/application.properties:147`, read via
  `@Value("${app.flyway.out-of-order:true}")` at
  `landlord/config/StartupFlywayMigrationRunner.java:60` — **default ON even if the property were
  absent**.
- It is passed to **both** datasource families: `.outOfOrder(outOfOrder)` at
  `landlord/service/StartupFlywayMigrator.java:212` (landlord) and **:295, inside the per-tenant
  loop** (tenants). So it does apply to tenant datasources, which was the specific question.
- `spring.flyway.enabled=false` (`application.properties:150`) and Boot's Flyway auto-config is
  excluded, so `spring.flyway.out-of-order` is inert — only the `app.` prefix is read.
- **It is empirically live in production**, not just configured. On Hydra PRD:
  `2.2.11` sits at `installed_rank = 17`, applied after `2.2.16` had already been installed. One
  real out-of-order application, on the one production tenant.

### M3 · The file is immutable from the moment the PR merges, and nothing in the plan says so

Merging to `wms2-api` `develop` triggers a dev deploy, which runs `StartupFlywayMigrator` on boot
(`app.flyway.migrate-on-startup=true`, `application.properties:141`). Dev then holds a
`flyway_schema_history` row with this file's CRC32 checksum. Any later edit — a renumber forced by
AC-6, a typo fix, even a comment change (the checksum is computed over every line;
`db/backfill-flyway-history.sh:130-154`) — makes `validateOnMigrate` fail and freezes dev's chain
until someone runs `flyway repair`.

Practical consequence for AC-6: the collision re-check must happen **before** merge, as the plan
says, because after merge a renumber is no longer a rename — it is a rename plus a repair on dev.
Worth one line in §2.3.

### M4 · The two-statement pattern has a silent copy-paste failure mode with no instrument

Statement 2 must guard on constant **B** while statement 1 guards on constant **A**. If the guard is
copy-pasted and statement 2 checks `function = 'WEB_UI_ACTION_RECOVER_STUCK_PALLETS'`, then:

- on a fresh apply, statement 1 inserts A, statement 2's guard sees A present and **skips** — B is
  never created, silently, and the migration reports success;
- the grant statement then grants only A;
- three of the four routes 403 for everyone.

Nothing catches this. A migration IT (H1) would, if it asserts a **count of 2** rather than the
existence of one. So would AC-3, if it is phrased as "both constants present with a super-admin
grant" rather than "the query ran". Phrase it that way.

---

## Low

### L1 · Attacks that failed — recorded so the budget is not re-spent

- **Case / whitespace defeat of the `WHERE NOT EXISTS` guard.** No row on any tenant matches either
  constant under `upper(btrim(...))` on `function` **or** on `name` (probe `I` = none ×6), and no row
  anywhere has untrimmed `function` (probe `J` = 0 ×6). There is no near-miss row to collide with.
- **A pre-existing row with matching `function` but different `name`.** Zero such rows fleet-wide
  (probe `H` = 0 ×6). Latent only; see H3.
- **`name IS NULL`.** Zero rows on all six (probe `G` = 0). The `COALESCE(name,'')` in my probe was
  defensive and found nothing.
- **Two roles named `super-admin`.** Impossible: `mywms_role` carries
  `uk_6yyotbpw7edc76ejucc4mflf2 UNIQUE (name)`, verified present on all six (probe `D` = 1). Also
  `uk_d3w5xk1nns0ibm6bhgfkishku UNIQUE (number)`. Case variants: probe `K` (`lower(btrim(name))`)
  and probe `L` (exact `=`) both return exactly 1 on all six, so no tenant has a `Super-Admin`.
- **`mywms_role_mywms_function` already holding the pair.** `WHERE NOT EXISTS` covers it, and it is
  now also backed by a PK on all six (probe `C`), so a bug there is a visible 23505 rather than a
  duplicate row.
- **Missing `client_id = 0` FK target.** Present on all six (probe `M` = 1) and in the base dump
  itself (`V2.2.00:2377`, `System-Client`), so a fresh Testcontainers DB satisfies it too.
- **Statement 2 not seeing statement 1's row.** Flyway executes a migration script in one
  transaction (default `executeInTransaction=true`; PostgreSQL has transactional DDL), and a
  statement in a transaction sees that transaction's own prior writes regardless of isolation level.
  It also works under the `psql -f` provisioning path, where each statement autocommits in order.
  Either way statement 2's `MAX(id)` includes statement 1's row.
- **Two replicas migrating concurrently.** `StartupFlywayMigrator.java:55`: *"Concurrent replicas
  are safe — Flyway serializes per database via its own lock."*
- **Half-apply then retry.** A failed migration rolls back with its `flyway_schema_history` insert on
  PostgreSQL, so no `success=false` row is written and the next boot retries the whole file. Probe
  `O` = `none` on all six confirms it empirically — including on Hydra PRD, which is documented in
  `StartupFlywayMigrator.java` as having spent twelve days frozen nine migrations behind. Combined
  with `WHERE NOT EXISTS` on every statement, retry converges.
- **A tenant already holding one constant but not the other.** Cannot arise today (0 of 2 on all
  six), and would converge anyway: statement 1 skips, statement 2 takes `max+1`.

### L2 · `SELECT DISTINCT` is *not* needed here — do not cargo-cult V2.2.19 STEP 6

V2.2.19 STEP 6 marks `SELECT DISTINCT` as load-bearing, correctly, because it joins *through*
`mywms_role_mywms_function` and a drifted tenant can reach one function by two rows. `V2.2.23`'s
grant joins only `mywms_role` (PK, UNIQUE(name)) to `mywms_function` (PK) with no path through the
join table, so it cannot emit a duplicate pair. Adding `DISTINCT` would be harmless but would
suggest a hazard that is not present. Conversely: now that the join table has a PK on all six
tenants, an intra-statement duplicate would be a 23505 abort rather than a silent duplicate row —
so where DISTINCT *is* needed it matters more than when V2.2.19 was written.

### L3 · A single-statement form exists — informational, not a recommendation

```sql
INSERT INTO mywms_function (id, created, modified, name, number, version, function, client_id)
SELECT COALESCE((SELECT MAX(id) FROM mywms_function), 0) + row_number() OVER (ORDER BY v.fn),
       now(), now(), v.fn, v.fn, 0, v.fn, 0
  FROM (VALUES ('WEB_UI_ACTION_RECOVER_STUCK_PALLETS'),
               ('WEB_UI_ACTION_SYSTEM_MANAGEMENT')) AS v(fn)
 WHERE NOT EXISTS (SELECT 1 FROM mywms_function f WHERE f.function = v.fn);
```

`WHERE` is evaluated before window functions, so `row_number()` numbers only the surviving rows and
the ids are contiguous whether one, both, or neither constant already exists. It removes M4's
copy-paste hazard by construction. I am **not** recommending the swap: the two-statement form
matches the precedent the reviewers know, and a novel pattern in a T3 migration trades a small
hazard for an unfamiliar one. Recorded only so the choice is deliberate.

### L4 · `app.flyway.out-of-order` could still be off in a deployed environment, and the repo cannot prove otherwise

The in-repo default is ON and the `@Value` default is ON, so it takes an explicit override to
disable — but Spring relaxed binding means `APP_FLYWAY_OUT_OF_ORDER=false` in the container
environment, or a line in the gitignored `application_dev.properties`, would do it silently. The
cheap check is the boot log, which `StartupFlywayMigrationRunner.java:62-63` emits unconditionally:

```
Flyway out-of-order migrations: {} (app.flyway.out-of-order)
```

Grep a deploy log for `ENABLED` once, per environment. Given M2 this is not on the critical path for
this ticket, but the plan asserts the flag's state and this is what would falsify it.

### L5 · `V2.2.23` is free as of this sweep, and `V2.2.22` has exactly one filename

Swept every remote branch (`git branch -r` → `git ls-tree -r --name-only <branch> --
src/main/resources/db/migration`), after `git fetch origin`. Only three files exist in the
`V2.2.2x` range fleet-wide:

```
V2.2.20__authorization_join_table_primary_keys
V2.2.21__seed_web_action_function_grants
V2.2.22__seed_order_batch_update_priority_sysprops
```

No branch carries a `V2.2.23`, and `V2.2.22` is not double-claimed. This confirms the plan's
correction (a), including its note that the script lives at
`src/main/resources/db/check-migration-version-collision.sh` and not under `sbdocs/9-System/scripts/`.
Per AC-6 this snapshot expires — re-run immediately before merge.

### L6 · Two adjacent tests to be aware of, neither blocking

- `FunctionGuardArchTest.flywayMigration_shouldDeclareV2_2_18_seed()`
  (`src/test/java/net/aim_ai/wms/unit/config/FunctionGuardArchTest.java:1013-1027`) lists
  `src/main/resources/db/migration` and asserts some file starts with `V2.2.18__`. Adding `V2.2.23`
  does not affect it.
- `RefillFixedLocationPredicateIntegrationTest`'s AC2 asserts an exact row set on the premise that
  *"no migration under `db/migration` inserts into `fix_location_assignment`, `replenishorder` or
  `stockunit` — checked 2026-09-01"* (:464-470). `V2.2.23` touches none of those three, so it stays
  valid. Worth knowing because it is the one test that would break if a future seed migration
  widened.
- `SyspropMigrationDescriptionWidthTest` scans every migration for `los_sysprop` seeds. `V2.2.23`
  writes none, so the `varchar(255)` `description` landmine genuinely does not apply — the plan's
  §2.1 bullet is correct.

---

## What the plan should change

1. **Add `UtilRestController.initDB` to §3 and to AC-1** — two `role_super_admin` grant lines — plus
   a parity assertion in `UtilRestControllerSeedUnitTest` mirroring `C-8d`. (C1)
2. **Delete §4.3's "nothing executes the migration" bullet and add an AC for a migration
   integration test** in the failsafe lane, asserting: 2 new `mywms_function` rows, distinct ids, and
   2 `mywms_role_mywms_function` rows for `super-admin`. (H1, M4)
3. **Add a revert paragraph**: forward-only via a `V2.2.24` that deletes grants then functions; never
   delete the applied file. (H2)
4. **Key the grant's join on `f.function`, not `f.name`.** (H3)
5. **Rewrite §2.1's two-statement rationale**: `mywms_function` has always had PK(id) + UNIQUE(function)
   on every tenant, so the failure mode is a visible 23505, not a silent duplicate; and V2.2.20 gave
   the join table a PK on all six tenants including PRD. (M1)
6. **Rewrite §2.3**: both `V2.2.22` and `V2.2.23` ship in the same image and apply in ascending order,
   so out-of-order is not engaged. Keep AC-3's both-versions check; retarget the out-of-order
   discussion at the late-merging-lower-version case, and note the file is checksum-immutable after
   merge. (M2, M3)

---

## Appendix — the probe

Run verbatim against each of the six tenant DBs via MCP `execute_sql`, 2026-09-01. Read-only.

```sql
SELECT 'A fn_pk_present' AS probe, count(*)::text AS val FROM pg_constraint c
  JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace
  WHERE n.nspname='public' AND t.relname='mywms_function' AND c.contype='p'
UNION ALL SELECT 'B fn_uniq_function', count(*)::text FROM pg_constraint c
  JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace
  WHERE n.nspname='public' AND t.relname='mywms_function' AND c.contype='u'
UNION ALL SELECT 'C join_pk_present', count(*)::text FROM pg_constraint c
  JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace
  WHERE n.nspname='public' AND t.relname='mywms_role_mywms_function' AND c.contype IN ('p','u')
UNION ALL SELECT 'D role_uniq_name', count(*)::text FROM pg_constraint c
  JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace
  WHERE n.nspname='public' AND t.relname='mywms_role' AND c.contype='u'
    AND pg_get_constraintdef(c.oid)='UNIQUE (name)'
UNION ALL SELECT 'E fn_count', count(*)::text FROM mywms_function
UNION ALL SELECT 'F fn_max_id', COALESCE(max(id),0)::text FROM mywms_function
UNION ALL SELECT 'G fn_name_null', count(*)::text FROM mywms_function WHERE name IS NULL
UNION ALL SELECT 'H fn_num_ne_func', count(*)::text FROM mywms_function
  WHERE number IS DISTINCT FROM function OR name IS DISTINCT FROM function
UNION ALL SELECT 'I fn_ws_or_case_variant', COALESCE(string_agg('['||function||']',' '),'none')
  FROM mywms_function
  WHERE upper(btrim(function)) IN ('WEB_UI_ACTION_RECOVER_STUCK_PALLETS','WEB_UI_ACTION_SYSTEM_MANAGEMENT')
     OR upper(btrim(COALESCE(name,''))) IN ('WEB_UI_ACTION_RECOVER_STUCK_PALLETS','WEB_UI_ACTION_SYSTEM_MANAGEMENT')
UNION ALL SELECT 'J fn_func_untrimmed_any', count(*)::text FROM mywms_function
  WHERE function <> btrim(function)
UNION ALL SELECT 'K superadmin_rows', COALESCE(string_agg(id||':['||name||']',' '),'NONE')
  FROM mywms_role WHERE lower(btrim(name))='super-admin'
UNION ALL SELECT 'L superadmin_exact', count(*)::text FROM mywms_role WHERE name='super-admin'
UNION ALL SELECT 'M client_id_zero', count(*)::text FROM client WHERE id=0
UNION ALL SELECT 'N flyway_max', COALESCE(max(version),'NONE') FROM flyway_schema_history WHERE success
UNION ALL SELECT 'O flyway_failed', COALESCE(string_agg(version||'/'||installed_rank,' '),'none')
  FROM flyway_schema_history WHERE NOT success
UNION ALL SELECT 'P flyway_versions_2_2_1x',
  COALESCE(string_agg(version||'(r'||installed_rank||')',' ' ORDER BY installed_rank),'none')
  FROM flyway_schema_history WHERE version >= '2.2.18' AND success
UNION ALL SELECT 'Q pg_version', substring(version(),1,20)
ORDER BY 1;
```

Out-of-order evidence (Hydra PRD), returning one row — `rank 17, version 2.2.11, applied AFTER
higher version 2.2.16`:

```sql
WITH h AS (SELECT installed_rank, version FROM flyway_schema_history WHERE version IS NOT NULL)
SELECT a.installed_rank, a.version FROM h a
 WHERE EXISTS (SELECT 1 FROM h b WHERE b.installed_rank < a.installed_rank
                 AND string_to_array(b.version,'.')::int[] > string_to_array(a.version,'.')::int[])
 ORDER BY a.installed_rank;
```

Post-deploy verification for AC-3 — run per tenant, expect exactly 2 rows, both naming
`super-admin`. A count of 1 is M4; a count of 0 with a clean Flyway run is H3 or a skipped role:

```sql
SELECT f.function, f.id, string_agg(r.name, ', ' ORDER BY r.name) AS roles
  FROM mywms_function f
  LEFT JOIN mywms_role_mywms_function rf ON rf.functionlist_id = f.id
  LEFT JOIN mywms_role r ON r.id = rf.rolelist_id
 WHERE f.function IN ('WEB_UI_ACTION_RECOVER_STUCK_PALLETS','WEB_UI_ACTION_SYSTEM_MANAGEMENT')
 GROUP BY f.function, f.id ORDER BY f.function;

SELECT version, installed_rank, success FROM flyway_schema_history
 WHERE version IN ('2.2.22','2.2.23') ORDER BY installed_rank;
```
