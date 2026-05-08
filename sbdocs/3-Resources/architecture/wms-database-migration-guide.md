---
type: architecture
status: active
system: wms1+wms2
last_verified: 2026-05-08
---

# WMS Database Migration Guide

Practical reference for writing safe Flyway migrations in v1/wms-api and v2/wms2-api. Consult this before writing any migration that touches a table with production data.

---

## §1 Versioning Conventions

### Naming format

```
V{major}.{minor}.{patch}__{snake_case_description}.sql
```

Both codebases use **double underscore** before the description. The single-underscore file `V1.26.28_wms_functions.sql` in v1 is a known anomaly that Flyway accepted but is **not the correct format** — do not replicate it.

### v1/wms-api sequences

The v1 migration directory currently ends at `V1.1.05`. The `V1.26.28` file (single underscore) is out of sequence and appears to be a one-off hotfix.

| Series | Purpose | Last used |
|--------|---------|-----------|
| `V1.0.xx` | Initial schema, views, functions, seed data, indexes | `V1.0.05` |
| `V1.1.xx` | Incremental updates (DDL, DML, view refreshes, function updates) | `V1.1.05` |

**Next migration to add**: `V1.1.06__your_description.sql`

To confirm the current highest number before creating a file:

```bash
ls /Users/np1076/dev/spk/owl/v1/wms-api/src/main/resources/db/migration/ | sort | tail -5
```

### v2/wms2-api sequences

The v2 migration directory currently ends at `V1.1.11`.

**Next migration to add**: `V1.1.12__your_description.sql`

To confirm:

```bash
ls /Users/np1076/dev/spk/owl/v2/wms2-api/src/main/resources/db/migration/ | sort | tail -5
```

### Rules

- **Never use repeatable (`R__`) migrations** in either codebase. Views and functions are replaced via versioned `CREATE OR REPLACE` statements (see `V1.1.01__wms_views.sql`, `V1.1.04__wms_functions.sql`).
- **Never modify an existing migration file.** Flyway checksums every applied migration; editing one causes the next startup to fail with a checksum mismatch error.
- **Never reuse a version number.** If a migration fails partway through, fix it in the same file before it is applied to any environment, then increment the version once it has been applied anywhere.

### Migration target

Both v1 and v2 apply Flyway migrations against **tenant databases only**. The landlord (master config) database is managed separately and has no migration files in these repos. The test harness (`AppPostgresDBSetupExtension`) spins up a Testcontainers PostgreSQL instance and runs `flyway.migrate()` against `classpath:db/migration` — the same files as production.

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

**Flyway caveat**: Flyway wraps each migration in a transaction by default. `CREATE INDEX CONCURRENTLY` will fail inside a transaction. To disable the transaction wrapper for a specific migration, add this comment at the top of the file:

```sql
-- Flyway: no transaction
CREATE INDEX CONCURRENTLY index_pickingorder_state ON pickingorder (state);
```

Migrations V1.1.09–V1.1.11 in v2 use standard `CREATE INDEX` (not `CONCURRENTLY`). These were safe to apply in a maintenance window; for future index additions on hot tables, prefer `CONCURRENTLY`.

### DROP COLUMN — safe DDL, but verify nativeQuery usages first

PostgreSQL marks dropped columns invisible immediately (no table rewrite until `VACUUM FULL`). The DDL itself is safe, but v1 has **277 native queries** and v2 has **171 native queries** that bypass JPQL. A dropped column that appears in a `SELECT *` or an explicit column list in a native query causes a runtime error the next time that query executes — not a compile-time error.

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
| `CREATE INDEX` (non-concurrent) | Blocks writes | `CREATE INDEX CONCURRENTLY` |
| `ADD CONSTRAINT ... CHECK` (validated) | Blocks briefly but validates all rows | `NOT VALID` + `VALIDATE CONSTRAINT` |
| `TRUNCATE` | Exclusive lock + WAL logged | Almost never correct in a migration |
| `DROP TABLE` | Immediate, irreversible | Needs explicit sign-off |

### The v1 native query problem

v1/wms-api has **277 `nativeQuery = true`** annotations. These queries reference column names, table aliases, and in some cases `SELECT *`. Because they are strings, the compiler cannot catch schema drift. A column rename or drop that is not reflected in every native query will produce a runtime `PSQLException` the first time that code path executes in production — often during peak operations.

v2/wms2-api has **171 native queries** with the same risk profile.

### How to grep native queries before a schema change

Before any schema change to column `col_name` on table `table_name`:

```bash
# Find all native query files that mention the column name (v1)
grep -rn "col_name" \
  /Users/np1076/dev/spk/owl/v1/wms-api/src/main/java/ \
  --include="*.java" | grep -i "nativeQuery\|query\s*="

# Broader sweep — find all .java files containing the column name string
grep -rln "col_name" \
  /Users/np1076/dev/spk/owl/v1/wms-api/src/main/java/ \
  --include="*.java"

# Same for v2
grep -rln "col_name" \
  /Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/ \
  --include="*.java"
```

Also grep views and functions in the migration files themselves — v1 has complex reporting views and `transaction_detail` PL/pgSQL functions that reference column names directly:

```bash
grep -rn "col_name" \
  /Users/np1076/dev/spk/owl/v1/wms-api/src/main/resources/db/migration/
grep -rn "col_name" \
  /Users/np1076/dev/spk/owl/v2/wms2-api/src/main/resources/db/migration/
```

### `@Column(name = ...)` overrides

Both codebases use Hibernate's default naming strategy. Column names are derived from the field name (camelCase → snake_case). When a field has an explicit `@Column(name = "...")` annotation, that name is the actual column name regardless of what the field is called. Before renaming a column, verify:

```bash
grep -rn "@Column" \
  /Users/np1076/dev/spk/owl/v1/wms-api/src/main/java/ \
  --include="*.java" | grep "name\s*=\s*\"col_name\""
```

---

## §4 Multi-Tenant Considerations (v2 only)

### Two separate databases: landlord and tenant

v2/wms2-api has a dual DataSource / dual EntityManager setup:

- **Landlord database** (`dev_landlord`): stores tenant configuration (which DB each tenant uses, Keycloak settings). Managed by `LandlordDatabaseConfig`. No migration files in this repo target the landlord DB.
- **Tenant databases**: one PostgreSQL database per tenant, routed dynamically by `TenantDynamicRoutingDataSource` using a 4-char key derived from `tenant_name` + `facility_code` HTTP headers.

**All migration files in `v2/wms2-api/src/main/resources/db/migration/` target tenant databases.** There is no mechanism in this codebase to auto-apply a migration to the landlord DB — that must be done by hand against `dev_landlord` (or the equivalent in each environment).

### Applying a new migration to all tenant DBs

Flyway is configured via Spring Boot auto-configuration and runs at startup time. When a new migration file is present, it will be applied automatically on the next application startup against whichever tenant database that startup is configured to use.

In practice, for a multi-tenant deployment:

1. Deploy the new JAR with the migration file present.
2. On startup, Spring Boot's Flyway auto-configuration runs `migrate()` against the **default DataSource** — in v2 this is the `tenantDynamicRoutingDataSource`. The routing DataSource resolves to whichever tenant is set in `TenantContext` at startup. Confirm with the infrastructure team how tenant DBs are migrated at deploy time (whether there is a bootstrap migration step or whether each tenant DB is migrated on first request).
3. Verify the `flyway_schema_history` table in each tenant DB after deployment.

### Landlord schema changes

If a change is needed to the landlord schema (e.g., adding a new column to the `tenant_config` table), it must be:

1. Applied manually against the landlord database, or
2. Managed through a separate migration path not yet formalized in this codebase.

Do not add landlord-targeting SQL to the tenant migration files.

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
- [ ] `CREATE INDEX` uses `CONCURRENTLY` + `-- Flyway: no transaction` directive for live tables.
- [ ] `ADD CONSTRAINT CHECK` uses `NOT VALID` + separate `VALIDATE CONSTRAINT`.

**Local verification**
- [ ] Run `mvn verify` (v1 or v2) — this spins up Testcontainers PostgreSQL and runs Flyway migrate + all integration tests against the full migration set.
- [ ] Confirm no Flyway checksum errors (means an existing migration file was accidentally modified).
- [ ] Confirm no `PSQLException` in test output that could indicate a broken native query.

```bash
# v1
cd /Users/np1076/dev/spk/owl/v1/wms-api && mvn verify

# v2
cd /Users/np1076/dev/spk/owl/v2/wms2-api && mvn verify
```

---

## §6 Rollback Strategy

Flyway Community Edition does not support automatic undo/rollback. Once a migration is applied, it cannot be reversed by Flyway itself.

### Manual undo migration pattern

Write the rollback as the **next migration version**:

```
V1.1.06__add_note_column_to_advice.sql       ← forward
V1.1.07__rollback_note_column_from_advice.sql ← undo (only deploy if needed)
```

The undo migration file should contain the exact inverse DDL:

```sql
-- V1.1.07__rollback_note_column_from_advice.sql
-- Undo of V1.1.06: removes the note column added to advice
ALTER TABLE advice DROP COLUMN IF EXISTS note;
```

### What to prepare before deploying

1. Write the undo migration file **before** deploying the forward migration.
2. Keep the undo file in a `rollback/` directory or in a branch — do not commit it to `db/migration/` unless the rollback is actually needed.
3. For DML-only migrations (INSERT/UPDATE), prepare a matching DELETE/UPDATE script and keep it ready.
4. For index additions, the undo is `DROP INDEX CONCURRENTLY index_name` — write it before you deploy.

### What cannot be undone easily

- `DROP COLUMN` — data is gone. Require a backup confirmation before deploying.
- `ALTER TYPE` with table rewrite — restoring the old type requires another full rewrite.
- `DROP TABLE` — requires restore from backup.

For these operations, take a manual PostgreSQL dump of the affected table(s) immediately before applying the migration in each environment.
