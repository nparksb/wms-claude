---
type: architecture
status: active
system: wms1+wms2
last_verified: 2026-11-11
verified_against: wms2-api origin/develop @ df30fa62 (v2 sections); v1 sections not re-read (see log)
---

# WMS Database Migration Guide

Practical reference for writing safe Flyway migrations in v1/wms-api and v2/wms2-api. Consult this before writing any migration that touches a table with production data.

---

## §1 Versioning Conventions

### Naming format

```
V{major}.{minor}.{patch}__{snake_case_description}.sql
```

Both codebases use **double underscore** before the description. ⚠ unverified 2026-11-11: v1/wms-api was not re-read in this pass; every v1 statement in this guide (series, `V1.26.x`, `outOfOrder=false`, 277 native queries) is as of the 2026-06-02 verification. The single-underscore file `V1.26.28_wms_functions.sql` in v1 is a known anomaly that Flyway accepted but is **not the correct format** — do not replicate it.

### v1/wms-api sequences

The shared schema baseline (identical to v2) ends at `V1.1.05`. **`V1.1.06+` is the active v1-specific series and is carried on `develop`** — do not assume `V1.1.06` is free just because it is absent from your branch. There is also an out-of-band **`V1.26.x` hotfix range**: `V1.26.28_wms_functions.sql` (anomalous single underscore — see naming note above) and `V1.26.29__replenishment_monitor_view_flag_based_classification.sql` (SBDEV-2384 hotfix).

| Series | Purpose | Last used |
|--------|---------|-----------|
| `V1.0.xx` | Initial schema, views, functions, seed data, indexes | `V1.0.05` |
| `V1.1.xx` | Incremental updates (DDL, DML, view refreshes, function updates) — continues on `develop` | `V1.1.06+` (on `develop`) |
| `V1.26.xx` | Out-of-band hotfixes that must merge cleanly into both `release` and `develop` without colliding with the in-flight `V1.1.x` series | `V1.26.29` |

**Choosing the next version — check more than your own branch.** Because the same baseline is built on both `release` and `develop`, a number that is free on your branch may already be taken on the other, causing a merge collision (and, with `outOfOrder=false`, a lower number than an already-applied higher one fails validation). Before naming a file:

1. List the highest versions on **your branch**:
   ```bash
   ls /home/nampark/dev/wms-claude/v1/wms-api/src/main/resources/db/migration/ | sort -V | tail -5
   ```
2. Check `develop` for the same/higher number (`git show develop:...` or browse the branch).
3. Confirm the highest **applied** version on the target tenant DB: `SELECT version FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 5;`.

For a **hotfix** that must land on both `release` and `develop`, prefer the **`V1.26.x` range** (strictly above the existing `V1.26.28`/`V1.26.29`) rather than reusing a `V1.1.x` slot that `develop` may already occupy — this is exactly why SBDEV-2384 was renamed from `V1.1.06` to `V1.26.29`.

### v2/wms2-api sequences

**Layout reorganized (2026-07-10).** `db/migration/` no longer holds the incremental history. It now holds only the fresh-start **base dump** (`V2.2.00__base_v2_schema.sql`, captured at the `V2.1.16` watermark) plus **new** post-cutover deltas (`V2.2.x`). The historical linear scripts `V1.0.*→V2.1.1x` moved to `db/v1-to-v2-onboarding/schema/` (the v1→v2 migration toolkit); see `v1-to-v2-onboarding/README.md`.

**Two independent version lines, two directories** (verified 2026-11-11 on `origin/develop` @ df30fa62):

| Set | Location (`StartupFlywayMigrator.java:61-62`) | Files | Latest |
|-----|------|-------|--------|
| Tenant DBs | `classpath:db/migration` | `V2.2.00` – `V2.2.50` (51 SQL files, contiguous, no `R__`) | `V2.2.50__message_redeliver_id_index.sql` |
| Landlord DB | `classpath:db/landlord-migration` | `V2.1.00` – `V2.1.02` (3 SQL files) | `V2.1.02__tenant_is_demo.sql` |

The historical `db/v1-to-v2-onboarding/schema/` set (32 files, `V1.0.01` – `V2.1.17`) is **not** a runtime location; only the bridge scripts and the base-dump provenance use it. Its head is `V2.1.17__lock_report_exclude_shipped.sql` (added 2026-07-15, the twin of `V2.2.02`); the in-repo README and `04-schema-bridge.sh` still say the set ends at `V2.1.16`.

Tenant versions added since the previous verification of this guide (2026-06-02): all of `V2.2.00`–`V2.2.50`, first dated `V2.2.00` 2026-07-12 and the newest `V2.2.50` 2026-11-11 (file-add dates from `git log --diff-filter=A`). Landlord versions `V2.1.00`–`V2.1.02` are new in the same window (`V2.1.02` is SBDEV-3868 per its header).

**Next migration to add**: the next free `V2.2.x__your_description.sql` in `db/migration/` (landlord DDL: `V2.1.x` in `db/landlord-migration/`). `ls` alone is not enough: unmerged branches hold versions nothing local can see. Run `bash src/main/resources/db/check-migration-version-collision.sh [V2.2.NN]` from inside the repo, first before naming the file and again just before merge (it also reads sibling worktrees and local branches; needs git 2.36+).

To list the highest existing tenant versions on your checkout:

```bash
ls src/main/resources/db/migration/ | grep -E '^V' | sort -V | tail -5   # run from the wms2-api repo root
```

**Out-of-order is ON in v2.** `app.flyway.out-of-order=true` (`application.properties:285`; default `true` in `StartupFlywayMigrationRunner`). A lower version that merges after a higher one is applied anyway, so version order no longer implies execution order: write migrations that do not depend on each other. Use `app.flyway.out-of-order`, not `spring.flyway.out-of-order` (Boot's Flyway auto-configuration is excluded, `spring.flyway.enabled=false`, so that key is inert). `db/check-tenant-migration-drift.sh` compares applied version *sets*, not `max(version)`.

### Rules

- **Never use repeatable (`R__`) migrations** in either codebase. Views and functions are replaced via versioned `CREATE OR REPLACE` statements (see `V1.1.01__wms_views.sql`, `V1.1.04__wms_functions.sql`).
- **Never modify an existing migration file.** Flyway checksums every applied migration; editing one causes the next startup to fail with a checksum mismatch error.
- **Never reuse a version number.** If a migration fails partway through, fix it in the same file before it is applied to any environment, then increment the version once it has been applied anywhere.

### Migration target

**v2** applies Flyway to **both** database kinds: tenant DBs from `classpath:db/migration` and the landlord DB from `classpath:db/landlord-migration` (see §1 table and §4). **v1** applies Flyway to tenant databases only (⚠ unverified 2026-11-11: v1 not re-read). The v2 test harness (`AppPostgresDBSetupExtension`) starts a shared `postgres:14-alpine` Testcontainer, migrates `classpath:db/migration` into it, creates a second database `wms_landlord_test` and migrates `classpath:db/landlord-migration` into that (`AppPostgresDBSetupExtension.java:51-81`, `AppPostgresDBContainer.java:31`). It no longer migrates `db/v1-to-v2-onboarding/schema` (SBDEV-3239; pinned by `PostgresTestHarnessPinTest`). v1 still uses `classpath:db/migration`.

---

## §2 Safe Patterns for Live Tables

PostgreSQL version in use: **PostgreSQL 11+** (both v1 and v2 target DigitalOcean managed PostgreSQL).

### ADD COLUMN with DEFAULT — safe, lock-free

PostgreSQL 11+ stores the default in the catalog and does not rewrite the table. This is the preferred pattern for adding nullable or defaulted columns.

```sql
-- Safe: no table rewrite on PostgreSQL 11+
ALTER TABLE stockunit ADD COLUMN reserved_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NULL;

ALTER TABLE customerorder ADD COLUMN priority_flag INTEGER DEFAULT 0 NOT NULL;
```

For `NOT NULL` columns with a constant default, PostgreSQL 11+ will also avoid a table rewrite as long as the default is a constant literal (not a function call). A `nextval()` or `now()` default still rewrites the table on older versions — test this assumption before deploying.

### ADD COLUMN NOT NULL without DEFAULT — requires a backfill strategy

Avoid adding a `NOT NULL` column in a single statement on large tables. Use a three-step approach:

```sql
-- Step 1: Add column as nullable
ALTER TABLE advice ADD COLUMN note VARCHAR(255);

-- Step 2: Backfill (do this in the same migration if the table is small,
--          or in a separate migration + background job for large tables)
UPDATE advice SET note = '' WHERE note IS NULL;

-- Step 3: Add the NOT NULL constraint
ALTER TABLE advice ALTER COLUMN note SET NOT NULL;
```

> See `V1.1.03__wms_updates.sql` — it adds `advice.note` exactly this way (step 1 only, presumably with application-level NOT NULL enforcement).

### CREATE INDEX CONCURRENTLY — non-blocking

Standard `CREATE INDEX` takes a ShareLock that blocks writes for the duration. For production tables use `CONCURRENTLY`. Note: `CONCURRENTLY` cannot run inside a transaction block — write it as a standalone statement.

```sql
-- Blocks writes — do not use on live tables without a maintenance window
CREATE INDEX index_pickingorder_state ON pickingorder (state);

-- Non-blocking — preferred for production
CREATE INDEX CONCURRENTLY index_pickingorder_state ON pickingorder (state);
```

> ⚠ **v2 tenant migrations (`db/migration/`): do NOT use `CONCURRENTLY`.** ✓ merged(SBDEV-4092: #658 2f995325, 2026-11-10; confirmed ancestor of develop df30fa62). It **hangs forever** under `StartupFlywayMigrator`. Flyway 11's default PostgreSQL lock (`flyway.postgresql.transactional.lock=true`, which `tenantConfiguration` leaves as is) holds `pg_advisory_xact_lock` in an open transaction on a second connection for the whole migrate. `CONCURRENTLY` waits for that transaction's snapshot. Measured 2026-11-10 in `MessageCreatedIndexMigrationIT`: 9+ minutes on `Lock/virtualxid` until it was killed. The v2 operator path, the Flyway CLI that `db/migration/README.md` says `apply-pending-tenant-flyway.sh` runs, uses the same default lock, so it hangs there too (⚠ that script is not present anywhere in `origin/develop` @ df30fa62, only referenced from the README and `V2.2.20`). In addition, a `-- flyway:executeInTransaction=false` script may hold **only** non-transactional statements ("Detected both transactional and non-transactional statements … mixed is false"), and a failed non-transactional migration is recorded `success=false`, so the tenant stays blocked until someone runs `flyway repair`. Use a plain transactional `CREATE INDEX` with `SET LOCAL lock_timeout`, the way `V2.2.49__message_created_index.sql` does. That blocks writes for 2.5 s at 1.54M rows / 1.5 GB (warm-cache synthetic copy, PG14), and longer when the cache is cold. Keep that `lock_timeout` below the app's `wms.tenant.lock-timeout-ms` (3000). Canonical text: `wms2-api/src/main/resources/db/migration/README.md`, "Do not use CONCURRENTLY here". Making CONCURRENTLY usable means changing every tenant's Flyway lock mode first, which needs its own ticket.

**Flyway caveat (v1 only)**: Flyway wraps each migration in a transaction by default. `CREATE INDEX CONCURRENTLY` will fail inside a transaction. To disable the transaction wrapper for a specific migration, put `-- flyway:executeInTransaction=false` on the first line of the file, and put nothing in it except non-transactional statements.

Migrations V2.1.04–V2.1.06 in v2 use standard `CREATE INDEX` (not `CONCURRENTLY`). These were safe to apply in a maintenance window. For v2 that is still the pattern; see the warning above.

### DROP COLUMN — safe DDL, but verify nativeQuery usages first

PostgreSQL marks dropped columns invisible immediately (no table rewrite until `VACUUM FULL`). The DDL itself is safe, but v1 has **277 native queries** (⚠ unverified 2026-11-11: v1 not re-counted) and v2 has **233 native queries** that bypass JPQL. A dropped column that appears in a `SELECT *` or an explicit column list in a native query causes a runtime error the next time that query executes — not a compile-time error.

Before dropping any column, run the grep in §3.

### RENAME COLUMN — dangerous without a grep sweep

`ALTER TABLE t RENAME COLUMN old TO new` is instant DDL, but it silently breaks every native query, every `@Column(name = "old")` override, and every view or function referencing the old name. Do not rename columns without completing the full grep sweep in §3.

### ALTER TYPE / ADD CHECK CONSTRAINT — table lock duration

`ALTER TABLE t ALTER COLUMN c TYPE new_type` rewrites the entire table and holds an `AccessExclusiveLock` for the duration. For large tables this means extended downtime. Prefer adding a new column, backfilling, and migrating the application in stages.

`ALTER TABLE t ADD CONSTRAINT c CHECK (...)` acquires a full table lock for constraint validation. Use `ADD CONSTRAINT c CHECK (...) NOT VALID` to skip validation (fast, lock-free), then `VALIDATE CONSTRAINT c` separately (ShareUpdateExclusiveLock, does not block reads or writes).

```sql
-- Fast: marks constraint NOT VALID (existing rows not checked, new rows are)
ALTER TABLE customerorder ADD CONSTRAINT chk_state_range CHECK (state >= 0) NOT VALID;

-- Validate separately — runs concurrent with reads/writes
ALTER TABLE customerorder VALIDATE CONSTRAINT chk_state_range;
```

---

## §3 Patterns to Avoid

### Table-level locks

The following operations take an `AccessExclusiveLock` for their full duration, blocking all reads and writes:

| Operation | Risk | Alternative |
|-----------|------|-------------|
| `ALTER TABLE t ALTER COLUMN c TYPE ...` | Full table rewrite | Add new column + backfill + swap |
| `ALTER TABLE t ADD COLUMN c NOT NULL` (no default) | Rewrites table on PG < 11 | Three-step pattern (§2) |
| `CREATE INDEX` (non-concurrent) | Blocks writes | v1: `CREATE INDEX CONCURRENTLY`. **v2 tenant: keep it transactional** with `SET LOCAL lock_timeout`; CONCURRENTLY hangs under `StartupFlywayMigrator` (§ CREATE INDEX CONCURRENTLY) |
| `ADD CONSTRAINT ... CHECK` (validated) | Blocks briefly but validates all rows | `NOT VALID` + `VALIDATE CONSTRAINT` |
| `TRUNCATE` | Exclusive lock + WAL logged | Almost never correct in a migration |
| `DROP TABLE` | Immediate, irreversible | Needs explicit sign-off |

### The v1 native query problem

v1/wms-api has **277 `nativeQuery = true`** annotations. These queries reference column names, table aliases, and in some cases `SELECT *`. Because they are strings, the compiler cannot catch schema drift. A column rename or drop that is not reflected in every native query will produce a runtime `PSQLException` the first time that code path executes in production — often during peak operations.

v2/wms2-api has **233 native queries** with the same risk profile (`grep -rho 'nativeQuery *= *true' src/main/java | wc -l` on develop @ df30fa62 = 236 raw, minus 3 in comments = 233 live `nativeQuery = true` annotations, plus 2 `createNativeQuery` call sites).

### How to grep native queries before a schema change

Before any schema change to column `col_name` on table `table_name`:

```bash
# Find all native query files that mention the column name (v1)
grep -rn "col_name" \
  /home/nampark/dev/wms-claude/v1/wms-api/src/main/java/ \
  --include="*.java" | grep -i "nativeQuery\|query\s*="

# Broader sweep — find all .java files containing the column name string
grep -rln "col_name" \
  /home/nampark/dev/wms-claude/v1/wms-api/src/main/java/ \
  --include="*.java"

# Same for v2
grep -rln "col_name" \
  /home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/ \
  --include="*.java"
```

Also grep views and functions in the migration files themselves — v1 has complex reporting views and `transaction_detail` PL/pgSQL functions that reference column names directly:

```bash
grep -rn "col_name" \
  /home/nampark/dev/wms-claude/v1/wms-api/src/main/resources/db/migration/
grep -rn "col_name" \
  /home/nampark/dev/wms-claude/v2/wms2-api/src/main/resources/db/v1-to-v2-onboarding/schema/ \
  /home/nampark/dev/wms-claude/v2/wms2-api/src/main/resources/db/migration/
```

### `@Column(name = ...)` overrides

Both codebases use Hibernate's default naming strategy. Column names are derived from the field name (camelCase → snake_case). When a field has an explicit `@Column(name = "...")` annotation, that name is the actual column name regardless of what the field is called. Before renaming a column, verify:

```bash
grep -rn "@Column" \
  /home/nampark/dev/wms-claude/v1/wms-api/src/main/java/ \
  --include="*.java" | grep "name\s*=\s*\"col_name\""
```

---

## §4 Multi-Tenant Considerations (v2 only)

### Two separate databases: landlord and tenant

v2/wms2-api has a dual DataSource / dual EntityManager setup:

- **Landlord database**: the tenant registry (`tenant`, `tenant_discovery`, `tenant_db_configuration`, `tenant_auth_configuration`). Managed by `LandlordDatabaseConfig` (`landlordDataSource`, `@Primary`; pool `landlord.datasource.maximum-pool-size=10`, password from env `LANDLORD_DATASOURCE_PASSWORD`). Its schema **is** Flyway-managed: `db/landlord-migration/` holds `V2.1.00` (idempotent baseline, `CREATE ... IF NOT EXISTS` only) plus `V2.1.01`/`V2.1.02`.
- **Tenant databases**: one PostgreSQL database per tenant warehouse, routed dynamically by `TenantDynamicRoutingDataSource` using the key `first4(tenantName) + "-" + facilityCode` from the **`X-Tenant-ID`** and **`facility_code`** HTTP headers (`TenantKeyBuilder.java:10-25`; e.g. `loca-develop`).

**The `V2.2.x` files in `db/migration/` (and the historical `db/v1-to-v2-onboarding/schema/`) target tenant databases; `V2.1.x` files in `db/landlord-migration/` target the landlord.** Do not mix them: the two directories have independent version lines and independent `flyway_schema_history` tables. (`db/landlord/L001__add_active_flag.sql` is a legacy **manual** script, not on any Flyway location.)

### Applying a new migration to all tenant DBs

**Flyway runs at app startup, hand-built, not through Spring Boot's auto-configuration.** `StartupFlywayMigrationRunner` registers an `ApplicationRunner` (`@Order(HIGHEST_PRECEDENCE)`) that calls `StartupFlywayMigrator.migrateAll()` before the app reports ready. It is gated by `app.flyway.migrate-on-startup` (env `APP_FLYWAY_MIGRATE_ON_STARTUP`, default `true`, `application.properties:279`). Boot's own Flyway auto-configuration is excluded by class (`StartApplication`) and `spring.flyway.enabled=false`, because it would run the tenant set against the landlord DataSource. `flyway-core` is runtime scope (`pom.xml:341`).

1. Deploy the new JAR with the migration file present.
2. On boot `migrateAll()` migrates the **landlord first** (`classpath:db/landlord-migration`, `baselineOnMigrate(true)`, `baselineVersion("0")`), then reads `tenant_db_configuration` (`findByActiveTrue()`), de-duplicates by `db_url|db_user_name` and migrates each distinct **active** tenant database from `classpath:db/migration` (`tenantConfiguration(...)`: `outOfOrder` from the property, **`baselineOnMigrate(false)`**; `validateOnMigrate` stays at Flyway's default).
3. A tenant DB with a populated schema but **no `flyway_schema_history`** is skipped (logged at ERROR, counted in the stale gauge) and stays skipped on every boot until repaired once with `db/backfill-flyway-history.sh`. A failure on one tenant never blocks the boot or other tenants.
4. Verify afterwards: `SELECT installed_rank, version, success FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 5;` in each tenant DB; metrics `wms2.flyway.tenant.stale{tenant}`, `wms2.flyway.tenants.stale`, `wms2.flyway.tenant.ownership_drift{tenant}`, `wms2.flyway.enumeration_failed`; `db/check-tenant-migration-drift.sh` and `db/verify-tenant-schema-conformance.sh` for fleet-wide checks.

**Ownership trap.** The migration runs as the tenant's own app role (`db_user_name`). If any `public` object is owned by another role, `CREATE OR REPLACE`/`ALTER` fails with SQLSTATE 42501 and the whole tenant freezes at that version. Repair with `db/reassign-tenant-ownership.sh` (see `db/migration/README.md`).

**On-demand provisioning uses the same configuration.** `PUT /landlord/tenants/{tenant}/warehouses/{warehouse}` (`TenantProvisioningController`, only when `rest.security.enabled=true`) creates the role and database (`TenantDatabaseCreator`), writes the landlord rows, then runs `StartupFlywayMigrator.tenantConfiguration(...)` migrate. All provisioning operations take advisory lock `TENANT_PROVISIONING` = **100012** (`AdvisoryLockService.java:292`) via `tryLock`, so a concurrent request gets 409.

### Landlord schema changes

Add the next `V2.1.x__description.sql` to `db/landlord-migration/`; it is applied on the next boot in every environment (a landlord failure is logged and never blocks the boot, so check the log for `Flyway landlord: N migration(s) applied`). Constraints for landlord migrations:

1. The app's landlord role must **own** the landlord tables and `landlord_id_sequence`, or every `ALTER` fails (Postgres checks ownership before `IF NOT EXISTS`). See `db/landlord-migration/README.md`.
2. `V2.1.00` is replayed against already-populated landlords by the `baselineOnMigrate(true)`/version-0 baseline, so it must stay idempotent. Never rewrite it.
3. Never put tenant-schema SQL here, and never put landlord SQL in `db/migration/`.

⚠ unverified 2026-11-11: live DB not queried. The landlord README records that dev, UAT and prd were at landlord version `2.1.00` on 2026-08-04; current live landlord versions (`2.1.01`, `2.1.02`) were not checked.

---

## §5 Verification Checklist

Before committing a migration:

**Naming**
- [ ] File follows `V{major}.{minor}.{patch}__{description}.sql` with double underscore.
- [ ] Version number is higher than all existing migrations in the same directory (`ls ... | sort | tail -5`).
- [ ] No existing migration file with the same version number.

**Content**
- [ ] Migration is idempotent where possible (`CREATE INDEX IF NOT EXISTS`, `CREATE TABLE IF NOT EXISTS`).
- [ ] `DROP` statements are preceded by `IF EXISTS`.
- [ ] No `DROP TABLE`, `TRUNCATE`, or irreversible destructive DDL without explicit approval.

**Native query sweep**
- [ ] Grepped all `.java` files in `v1/wms-api/src/main/java/` for affected column/table names.
- [ ] Grepped all `.java` files in `v2/wms2-api/src/main/java/` for affected column/table names.
- [ ] Grepped all migration `.sql` files for column names referenced in views or functions.
- [ ] Checked `@Column(name = "...")` annotations for the affected columns.

**Lock safety**
- [ ] No `ALTER TYPE` on large tables without a rewrite strategy.
- [ ] v1: `CREATE INDEX` on a live table uses `CONCURRENTLY` + `-- flyway:executeInTransaction=false`. **v2 `db/migration`: never `CONCURRENTLY`** (it hangs on Flyway's own lock transaction); use a transactional `CREATE INDEX` with `SET LOCAL lock_timeout` and measure the build time.
- [ ] `ADD CONSTRAINT CHECK` uses `NOT VALID` + separate `VALIDATE CONSTRAINT`.

**Local verification**
- [ ] Run `mvn verify` (v1 or v2) — this spins up Testcontainers PostgreSQL and runs Flyway migrate + all integration tests against the full migration set.
- [ ] Confirm no Flyway checksum errors (means an existing migration file was accidentally modified).
- [ ] Confirm no `PSQLException` in test output that could indicate a broken native query.

```bash
# v1
cd /home/nampark/dev/wms-claude/v1/wms-api && mvn verify

# v2
cd /home/nampark/dev/wms-claude/v2/wms2-api && mvn verify
```

---

## §6 Rollback Strategy

Flyway Community Edition does not support automatic undo/rollback. Once a migration is applied, it cannot be reversed by Flyway itself.

### Manual undo migration pattern

Write the rollback as the **next migration version**:

```
V2.1.14__add_note_column_to_advice.sql       ← forward
V2.1.15__rollback_note_column_from_advice.sql ← undo (only deploy if needed)
```

The undo migration file should contain the exact inverse DDL:

```sql
-- V2.1.15__rollback_note_column_from_advice.sql
-- Undo of V2.1.14: removes the note column added to advice
ALTER TABLE advice DROP COLUMN IF EXISTS note;
```

### What to prepare before deploying

1. Write the undo migration file **before** deploying the forward migration.
2. Keep the undo file in a `rollback/` directory or in a branch — do not commit it to `db/migration/` unless the rollback is actually needed.
3. For DML-only migrations (INSERT/UPDATE), prepare a matching DELETE/UPDATE script and keep it ready.
4. For index additions, the undo is `DROP INDEX index_name` (v2 Flyway: never `CONCURRENTLY`, see above). Write it before you deploy.

### What cannot be undone easily

- `DROP COLUMN` — data is gone. Require a backup confirmation before deploying.
- `ALTER TYPE` with table rewrite — restoring the old type requires another full rewrite.
- `DROP TABLE` — requires restore from backup.

For these operations, take a manual PostgreSQL dump of the affected table(s) immediately before applying the migration in each environment.

---

## Verification log

| Date | Scope | Result |
|------|-------|--------|
| 2026-11-11 | v2 sections re-verified against `wms2-api` `origin/develop` @ df30fa62: migration locations, version lists (tenant `V2.2.00`–`V2.2.50`, landlord `V2.1.00`–`V2.1.02`), Flyway config (`StartupFlywayMigrator`, `StartupFlywayMigrationRunner`, `TenantWarehouseProvisioningService`, `application.properties`), test harness, native-query count, CONCURRENTLY warning against `db/migration/README.md`/`V2.2.49`. Corrected: landlord has Flyway migrations; Flyway is not Boot auto-config; harness location; routing key; native query count 171 → 236. v1 sections not re-read. | Code read only; live DB not queried. Next due 2027-01-10. |
