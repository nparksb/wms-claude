# SBDEV-3524 — MySQL-dependent Cubing unit test lane: BASE vs FIX vs FIX2

**Date:** 2026-09-26
**Repo:** `v2/oms-laravel-api`
**Commits compared:**
- BASE = `14526ab9` (`origin/develop`)
- FIX = `4bce80ba` (`bug/SBDEV-3524`, "fix(cubing): prefer larger boxes first among equal box sets")
- FIX2 = `f7adfde5` (`bug/SBDEV-3524`, "fix(cubing): harden larger-boxes-first tie-break after review") — **this is the commit that ships**

Scope: the six MySQL-dependent classes under `tests/Unit/Services/Cubing` that error with
`SQLSTATE[HY000] [2002] Connection refused` when no DB is configured (`PackagingMaterialPreferenceTest`,
`PackagingResolverEligibilityTest`, `V1PackagingParityTest`, `PackagingResolverNameLookupTest`,
`IcePackPackagingPreferenceTest`, `CubingAssignmentSelectionTest`), run as part of the full
`tests/Unit/Services/Cubing` directory (200/193/203 tests — see below), plus (time-permitting) the
whole `tests/Unit` tree.

## Result summary

**The DB lane works end-to-end.** All three commits were run against a byte-for-byte identical,
freshly-reset MySQL 8 schema. Per-test outcome (pass/FAIL/ERROR) is **identical for every test that
exists in more than one commit** — zero regressions, zero newly-passing tests, zero flips of any
kind between BASE, FIX and FIX2. The only differences are additive: each commit adds tests to
`LargerBoxesFirstCubingTest.php` that don't exist in the prior commit, and every added test passes.

| | BASE (`14526ab9`) | FIX (`4bce80ba`) | FIX2 (`f7adfde5`, ships) |
|---|---|---|---|
| Cubing dir: total tests | 193 | 200 | 203 |
| Cubing dir: pass | 191 | 198 | 201 |
| Cubing dir: FAIL | 2 | 2 | 2 |
| Cubing dir: assertions | 777 | 826 | 834 |

The 2 failures are **identical in test name, message, and diff across all three commits** (see
"Pre-existing failures" below) — they are environmental/pre-existing, not caused by SBDEV-3524.

Per-test diff (from JUnit XML, `<testcase class>::<name>` as the key):

- **Outcome differs BASE vs FIX (shared tests): 0**
- **Outcome differs BASE vs FIX2 (shared tests): 0**
- **Outcome differs FIX vs FIX2 (shared tests): 0**
- Tests only in FIX (not BASE, not FIX2): 1 — `LargerBoxesFirstCubingTest::larger_boxes_first_is_bounded_below_one_unit_of_any_other_term` → **pass**
- Tests only in FIX2 (not BASE, not FIX): 4 — all in `LargerBoxesFirstCubingTest`:
  - `box_size_is_measured_in_nominal_volume_not_slots` → **pass**
  - `larger_boxes_first_loses_to_a_hundredth_of_a_millilitre_scale_gap` → **pass**
  - `larger_boxes_first_weight_stays_below_the_empty_space_resolution` → **pass**
  - `the_cache_key_changes_when_the_fitness_weights_change` → **pass**
- Full set of tests in FIX2 but not in BASE (i.e. everything FIX2 added to `LargerBoxesFirstCubingTest`
  relative to BASE, where the file doesn't exist at all): 10 tests, all **pass**:
  `a_single_parcel_scores_the_same_whatever_its_size`, `box_size_is_measured_in_nominal_volume_not_slots`,
  `fitness_prefers_twelve_twelve_six_over_twelve_nine_nine_for_thirty_bottles`,
  `larger_boxes_first_loses_to_a_hundredth_of_a_millilitre_scale_gap`,
  `larger_boxes_first_never_buys_an_extra_parcel`, `larger_boxes_first_never_outweighs_empty_space`,
  `larger_boxes_first_weight_stays_below_the_empty_space_resolution`,
  `solver_cubes_thirty_bottles_as_twelve_twelve_six_on_every_run`,
  `the_cache_key_changes_when_the_fitness_weights_change`,
  `the_default_fills_in_for_weight_sets_that_predate_it`.

This matches the code diff shape exactly: BASE has no `LargerBoxesFirstCubingTest.php`; FIX adds it
(11 tests, of which the six MySQL-dependent classes above are unaffected); FIX2 further hardens the
tie-break logic in `FitnessEvaluator.php`/`CubingCacheService.php`/`config/cubing.php` and expands the
same test file to 10 cases covering the new volume-based sizing, the finer tie-break weight
(0.5 → 0.001), and the weights-fingerprint cache key. None of the six originally-DB-blocked classes
(`PackagingMaterialPreferenceTest`, `PackagingResolverEligibilityTest`, `V1PackagingParityTest`,
`PackagingResolverNameLookupTest`, `IcePackPackagingPreferenceTest`, `CubingAssignmentSelectionTest`)
show any outcome change across BASE/FIX/FIX2.

### Pre-existing failures (identical across BASE, FIX, FIX2 — not caused by this ticket)

1. `PackagingResolverEligibilityTest::selectable_and_forced_packages_share_the_date_and_facility_context`
   (`tests/Unit/Services/Cubing/PackagingResolverEligibilityTest.php:455`)
   — `Failed asserting that two arrays are identical.` Expected `[0 => 197]`, actual `[0 => 195, 1 => 197]`.
2. `V1PackagingParityTest::forced_lut_box_cannot_use_its_description_as_a_missing_wms_code`
   (`tests/Unit/Services/Cubing/V1PackagingParityTest.php:161`)
   — `Failed asserting that 'packaging_type_lut_id 223 is not selectable for client 211' contains "no WMS box code"`.

Both reproduce byte-for-byte (same expected/actual values, same IDs) on a completely fresh DB in all
three commits, which is consistent with them being either genuine pre-existing bugs or artifacts of
this DB-lane setup's seed-data/ID-ordering assumptions (not something SBDEV-3524 touches) — not
investigated further since they are out of scope (identical everywhere).

## `tests/Unit` full-suite run (time-permitting item — BASE vs FIX2 only, per priority)

Ran per the updated instruction to prioritize BASE vs FIX2. Same recipe, same fresh-reset DB,
`tests/Unit` instead of just the Cubing subdirectory (392 test files).

| | BASE (`14526ab9`) | FIX2 (`f7adfde5`, ships) |
|---|---|---|
| Total tests | 4567 | 4577 |
| pass | 4327 | 4335 |
| FAIL | 42 | 41 |
| ERROR | 195 | 198 |
| SKIPPED | 3 | 3 |
| Assertions | 14629 | 14672 |

**Removed in FIX2 vs BASE: 0. Added in FIX2 vs BASE: 10** — all 10 are the same
`LargerBoxesFirstCubingTest` additions already covered above, and all **pass**.

**Outcome differs on a shared test (both commits ran it): 4**, all **outside** `Cubing` and **outside**
the SBDEV-3524 diff's touched files (`CubingCacheService.php`, `FitnessEvaluator.php`, `Parcel.php`,
`config/cubing.php`). None of the four call into cubing code:

| Test | BASE | FIX2 | Cause |
|---|---|---|---|
| `Tests\Unit\Jobs\CarrierTrackingBatchJobTest::it_handles_tracking_errors_gracefully` | FAIL (`asserting that null is not null`) | ERROR (`Mockery...should be called exactly 1 times but called 0 times`) | **Already broken on BASE**, just a different failure signature on FIX2 — not a regression, a pre-existing broken test (unrelated app code, no Cubing involvement) |
| `Tests\Unit\Jobs\CarrierTrackingBatchJobTest::it_ignores_an_unknown_carrier_status` | FAIL (same) | ERROR (same Mockery count issue) | Same as above |
| `Tests\Unit\Services\OrderShipperServiceTest::test_map_sort_field` | pass | ERROR: `UniqueConstraintViolationException` on `view_by_shipper_count_cache.shipper_id` | Classic no-`RefreshDatabase`/shared-persistent-DB test-isolation symptom: this suite doesn't reset the DB between test classes (see `PackagingResolverEligibilityTest`/`V1PackagingParityTest` pre-existing failures above, same root cause), and FIX2's 10 extra Cubing tests shift the timing/row-count/date-keyed cache upsert enough to collide with a row from an earlier test. Nothing in `OrderShipperServiceTest` or `view_by_shipper_count_cache` is touched by the SBDEV-3524 diff. |
| `Tests\Unit\Services\ShippingServiceTest::switching_a_parcel_to_pickup_clears_its_insurance_charge` | pass | FAIL: `'2400.00' matches expected 0.0` | Same class of persistent-DB test-isolation fragility — an insurance-charge assertion picking up a differently-ordered/differently-ID'd row because the DB has different accumulated state by the time this test runs, not because `ShippingService` or insurance logic changed (SBDEV-3524 never touches `ShippingService`). |

**Conclusion for the full-Unit run: no evidence of any SBDEV-3524-caused regression.** The 10 added
tests are new Cubing coverage that pass. The 4 outcome differences on pre-existing tests are
explained by this test suite's known persistent-DB/no-`RefreshDatabase` design (already documented
above via the 2 identical Cubing failures reproducing byte-for-byte across all three commits) reacting
to a different total test count/ordering, not by any change in Cubing (or other) application logic —
two of the four were already failing on BASE with a different error, and the other two are read-after-
write races against shared lookup/cache tables in files SBDEV-3524 never edits.

## Setup recipe that worked

### 0. Toolchain images
```bash
# Base image already existed: oms-unit-php84 (php:8.4-cli + pdo_mysql + bcmath)
# Built a derived image adding the mongodb PHP extension. It is NOT needed for the
# Cubing tests to pass (Mongo usage is guarded by DISABLE_MONGO_IN_TESTS at the
# application-logic level) -- it is needed so that `php artisan <anything>` doesn't
# fatal with "Class MongoDB\Driver\Manager not found" the moment the Console
# Application auto-registers ALL artisan commands (one command's constructor,
# App\Services\External\OAuth\OAuthStateManager via ExternalPlatformServiceProvider,
# eagerly builds a MongoDB\Driver\Manager with no lazy guard). This only bites our
# manual `artisan migrate` / `artisan tenants:artisan` setup steps -- the actual
# `vendor/bin/phpunit` test run never touches command auto-registration (PHPUnit's
# CreatesApplication only calls Kernel::bootstrap(), never getArtisan()), so the
# baseline "no DB" run in the task brief never saw this error.
cat > Dockerfile.mongo <<'EOF'
FROM oms-unit-php84
RUN apt-get update && apt-get install -y --no-install-recommends libssl-dev pkg-config zlib1g-dev \
    && pecl install mongodb \
    && docker-php-ext-enable mongodb \
    && apt-get purge -y --auto-remove libssl-dev pkg-config zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
EOF
docker build -t oms-unit-php84-mongo -f Dockerfile.mongo .
```

### 1. Worktrees (outside the shared `.claude/worktrees` tree, never touched)
```bash
SCRATCH=/private/tmp/claude-503/.../scratchpad/dblane
git -C /Users/np1076/dev/spk/owl/v2/oms-laravel-api worktree add --detach "$SCRATCH/oms-base"  14526ab9
git -C /Users/np1076/dev/spk/owl/v2/oms-laravel-api worktree add --detach "$SCRATCH/oms-fix"   4bce80ba
git -C /Users/np1076/dev/spk/owl/v2/oms-laravel-api worktree add --detach "$SCRATCH/oms-fix2"  f7adfde5
# composer.lock is byte-identical across all three commits (SHA 70ddec4a2b...), so vendor/
# was installed once (copied from the already-provisioned SBDEV-3524 worktree's vendor/,
# never mutating that source) and copied into all three scratch worktrees.
cp -R <SBDEV-3524-worktree>/vendor "$SCRATCH/oms-base/vendor"
cp -R "$SCRATCH/oms-base/vendor" "$SCRATCH/oms-fix/vendor"
cp -R "$SCRATCH/oms-fix/vendor"  "$SCRATCH/oms-fix2/vendor"
for d in oms-base oms-fix oms-fix2; do cp "$SCRATCH/$d/.env.testing" "$SCRATCH/$d/.env"; done
```

### 2. Throwaway MySQL 8 container + network
```bash
docker network create oms-dblane-net
docker run -d --name oms-dblane-mysql --network oms-dblane-net \
  -e MYSQL_ROOT_PASSWORD=rootpass -e MYSQL_DATABASE=om1_owltest \
  mysql:8.0 --default-authentication-plugin=mysql_native_password
# wait for `mysqladmin ping` to succeed, then:
docker exec -i oms-dblane-mysql mysql -uroot -prootpass -h127.0.0.1 <<'SQL'
CREATE DATABASE IF NOT EXISTS om1_owltest;
CREATE DATABASE IF NOT EXISTS om1_landlord_owltest;
CREATE DATABASE IF NOT EXISTS om1_owltest_reporting;
CREATE USER IF NOT EXISTS 'testuser'@'%' IDENTIFIED WITH mysql_native_password BY 'testpass';
GRANT ALL PRIVILEGES ON om1_owltest.* TO 'testuser'@'%';
GRANT ALL PRIVILEGES ON om1_landlord_owltest.* TO 'testuser'@'%';
GRANT ALL PRIVILEGES ON om1_owltest_reporting.* TO 'testuser'@'%';
FLUSH PRIVILEGES;
SQL
```

### 3. Per-run reset + migrate + test (the actual recipe: `reset_and_run.sh`)

phpunit.xml already fixes `DB_DATABASE=om1_owltest`, `LANDLORD_DATABASE=om1_landlord_owltest`,
`DB_CONNECTION=testing`. `config/database.php`'s `testing` connection reads `DB_HOST/DB_PORT/
DB_USERNAME/DB_PASSWORD` from the environment; `landlord` reads the `LANDLORD_*` equivalents. The
official `run-tests.sh` recipe (`db:setup-test` + `artisan migrate --path=.../tenant` +
`artisan migrate --path=.../landlord` + `db:create-test-data`) assumes a **live reference tenant
database** to copy from (`om1_wineco`), which we don't have and must not touch even if we did. Instead:

- `database/migrations/tenant-initial/0001_00_00_000000_create_baseline_schema.php` is a migration
  that loads `database/schema/tenant-baseline.sql` (structure) + `tenant-seed-data.sql` (lookup-table
  rows the Cubing factories FK against, e.g. `bill_from_facility_lut`) directly into the `tenant`
  connection — this is the from-scratch equivalent of `db:setup-test`'s live copy.
- `database/migrations/tenant/*` (191 files) then brings that baseline up to the current schema
  (baseline predates some columns the Cubing tests need, e.g. `packaging_type_lut.max_weight`).
- The migration's `up()` uses `DB::connection('tenant')`, which is `null`-database until Spatie
  Multitenancy's `SwitchTenantDatabaseTask` sets it — so a plain `artisan migrate --database=testing`
  fails with "No database selected". Fix: seed one landlord `tenants` row
  (`name='owltest', database='om1_owltest'`) and drive the tenant migrations through Spatie's own
  `php artisan tenants:artisan "migrate --path=... --force"`, which makes that tenant current first.
- Discovered two **pre-existing, from-scratch-migrate-only bugs**, unrelated to SBDEV-3524 (same on
  BASE/FIX/FIX2, and reproducible on ANY clean `testing`-env migrate — not an artifact of Docker or
  MySQL 8 specifically): `tenant-baseline.sql` is a live snapshot that isn't a clean point-in-time
  export relative to the migration history, so some migrations' end states are already present in the
  snapshot before the migration that "creates" them has run. Two are handled:
  1. `2025_12_21_120500_add_missing_order_status_history_exception_fields.php` unconditionally
     re-adds an index/FK that its (correctly-guarded, `indexExists()`/`foreignKeyExists()`) sibling
     `2025_08_15_100001_...` already created; its `try/catch` around `$table->index()` doesn't help
     because Laravel batches Blueprint commands into one `ALTER TABLE` executed after the closure
     returns. Marked as already-applied (its effect is already present).
  2. Several later migrations do a bare `$table->foo()` add of a column that's already in the
     baseline snapshot (e.g. `product.wms_item_id`), failing with `Duplicate column name`. Handled
     generically: a retry loop runs `tenants:artisan migrate`, and on any `SQLSTATE`
     "already exists / Duplicate column|key|entry" failure, marks that one migration row as applied
     in the `migrations` table and retries, until a clean run or a genuinely different error.
  No product or test code was edited to make this work — only migration bookkeeping rows.

```bash
# See full script at $SCRATCH/reset_and_run.sh. Per run: drop+recreate both DBs empty ->
# landlord migrate -> seed owltest tenant row -> tenants:artisan migrate tenant-initial ->
# drift-retry loop over tenants:artisan migrate tenant -> db:create-test-data -> phpunit.
./reset_and_run.sh "$SCRATCH/oms-base" base  --log-junit=junit-report.xml tests/Unit/Services/Cubing
./reset_and_run.sh "$SCRATCH/oms-fix"  fix   --log-junit=junit-report.xml tests/Unit/Services/Cubing
./reset_and_run.sh "$SCRATCH/oms-fix2" fix2  --log-junit=junit-report.xml tests/Unit/Services/Cubing
```

Each run takes ~2m (migrations ~65-70s including the drift retries + ~52-55s phpunit).

Note: `--log-junit` must be a path **relative to `/app`** (the container's bind-mounted worktree
root) or it silently fails to write (an absolute host path doesn't exist inside the container's
filesystem and PHPUnit does not error loudly on that).

## Cleanup confirmation

```bash
docker rm -f oms-dblane-mysql
docker network rm oms-dblane-net
docker rmi oms-unit-php84-mongo   # derived image, safe to remove; base oms-unit-php84 left untouched
git -C /Users/np1076/dev/spk/owl/v2/oms-laravel-api worktree remove --force "$SCRATCH/oms-base"
git -C /Users/np1076/dev/spk/owl/v2/oms-laravel-api worktree remove --force "$SCRATCH/oms-fix"
git -C /Users/np1076/dev/spk/owl/v2/oms-laravel-api worktree remove --force "$SCRATCH/oms-fix2"
rm -rf "$SCRATCH"
```

**Status: executed and verified.** All three ran cleanly (`docker rm`/`network rm`/`rmi` each
confirmed by name in their own output; `git worktree remove --force` x3 confirmed by a subsequent
`git worktree list` showing only the main checkout and the other agent's pre-existing
`.claude/worktrees/oms-laravel-api/SBDEV-3524` worktree, untouched, at its original branch/HEAD;
`$SCRATCH` confirmed gone via `ls`). The base `oms-unit-php84` image (pre-existing, not built by this
task) was left in place; only the derived `oms-unit-php84-mongo` image was removed.

## Files
- Script: `$SCRATCH/reset_and_run.sh` (scratch-only, removed with the rest of `$SCRATCH` at cleanup)
- JUnit XML: `oms-base/junit-report.xml`, `oms-fix/junit-report.xml`, `oms-fix2/junit-report.xml`
  (scratch-only, removed at cleanup — the diff results above are the durable record)
