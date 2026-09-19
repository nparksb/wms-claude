---
name: oms-laravel-api-has-no-runnable-test-env
description: "How to run v2/oms-laravel-api's test suite (nothing is installed and no CI runs it) — working container recipe, the known develop baseline, and the three traps"
metadata: 
  node_type: memory
  type: reference
  originSessionId: af2f3b06-4643-4758-bc47-1a6aa0e91020
  modified: 2026-09-15T15:40:17.743Z
---

**Built and verified 2026-09-15.** `v2/oms-laravel-api` has **no PHP, no `vendor/`, no `.env`** on this
machine, and **no CI job runs its tests** (all three workflows are image builds; `grep -rln "artisan
test\|phpunit\|pest" .github/workflows/` → zero hits, unlike [[wms2-no-pipeline-runs-tests]]). So
nothing here is installed for you and a red suite is invisible everywhere. It IS runnable — recipe
below. **Needs no credentials and no dump: the schema is in the repo.**

```bash
# 1. image (PHP 8.4 + pdo_mysql, mongodb, redis, bcmath, zip, gd, intl) — build once
#    FROM php:8.4-cli; docker-php-ext-install pdo_mysql mysqli bcmath zip gd exif pcntl sockets intl
#    pecl install mongodb redis; COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
docker build -t oms-php:8.4 .
# 2. throwaway services — NEVER point this at a real MySQL (see the warning below)
docker run -d --name oms-test-mysql -e MYSQL_ROOT_PASSWORD=owltest -p 13306:3306 mysql:8.0
docker run -d --name oms-test-mongo -p 27018:27017 mongo:7
# 3. deps
docker run --rm -v "$WT":/app -e COMPOSER_ALLOW_SUPERUSER=1 oms-php:8.4 composer install
# 4. three databases, then load schema WITH BOTH PRAGMAS (see traps)
#    om1_owltest, om1_landlord_owltest, om1_owltest_reporting
#    PRE="SET SESSION sql_mode='NO_ENGINE_SUBSTITUTION'; SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;"
#    { echo "$PRE"; cat database/schema/tenant-baseline.sql; } | mysql ... om1_owltest   -> 205 tables
#    artisan migrate --path=database/migrations/landlord        --database=landlord          -> 18
#    artisan migrate --path=database/migrations/tenant-reporting --database=testing_reporting -> 5
# 5. run (env vars WIN: Laravel's Dotenv is immutable and won't override a set var)
docker run --rm --network host -v "$WT":/app -e APP_ENV=testing \
  -e DB_HOST=127.0.0.1 -e DB_PORT=13306 -e DB_USERNAME=root -e DB_PASSWORD=owltest ... \
  oms-php:8.4 php vendor/bin/phpunit --testsuite Unit --no-coverage
```

**Known develop baseline in THIS environment (ba6d92da): `Tests: 4123, Errors: 499, Failures: 48,
Skipped: 4`.** Not zero, and that is fine — a baseline must be *known*, not clean. Every remaining
error is schema drift (`om1_owltest_reporting.async_*` missing; unknown columns `max_weight`,
`lookup_hash`, `label_retry_count`). **The Qa/Return area is green** —
`tests/Unit/Services/Qa/QaReturnServiceValidationTest.php` is 8/8 OK, verified as a positive control
rather than inferred from an absence of failures.

Three traps, all of which silently produce a wrong-looking result:

1. **`tenant-baseline.sql` needs `FOREIGN_KEY_CHECKS=0`** — it references tables before creating them
   (`Failed to open the referenced table`). Same shape as the wms2 from-scratch ordering trap.
2. **It also needs a permissive `sql_mode`** — it is a 5.7-era dump and MySQL 8 rejects its zero-date
   defaults (`Invalid default value for 'created'`). ⚠ `mysql:8.0` was chosen ARBITRARILY; production's
   version is unconfirmed, so this is NOT parity — re-derive it before trusting a version-sensitive result.
3. **The baseline ships `CREATE TABLE migrations` with ZERO rows**, so `artisan migrate` replays all
   185 tenant migrations against a schema that already has most of them and dies on a duplicate index.
   Don't run the tenant set; the baseline already contains it.

⚠ **Never point the suite at a real database.** 17 test files use `RefreshDatabase`, which drops and
rebuilds every table on the `testing` connection. `config/database.php` hardcodes that connection's
name to `om1_owltest`, but **`LANDLORD_DATABASE` and `REPORTING_DATABASE` are NOT hardcoded** — and
the committed `.env.testing` points them at `om1_landlord_owltest`/`dev_om1_wineco_reporting`. A real
MySQL URL plus those defaults rebuilds real databases. See [[oms-laravel-api-committed-env-secrets]].
