#!/usr/bin/env bash
# reset_and_run.sh — rebuilt recipe for running v2/oms-laravel-api's tests/Unit suite
# against a throwaway, persistent (not-refreshed-between-classes) MySQL 8 DB, so
# test-order/DB-state pollution effects can be reproduced and compared across commits.
#
# Usage: ./reset_and_run.sh <worktree-dir> <label> [extra phpunit args...]
#   e.g. ./reset_and_run.sh /path/to/A-base base --log-junit=junit-base.xml
#        ./reset_and_run.sh /path/to/A-base base --filter=test_map_sort_field
#
# Assumes:
#  - A docker network `oms-flipcheck-net` exists
#  - A `mysql:8.0` container named `oms-flipcheck-mysql` is running on that network
#    with databases om1_owltest / om1_landlord_owltest / om1_owltest_reporting and
#    user testuser/testpass granted on all three
#  - The image `oms-unit-php84-mongo-flipcheck` (oms-unit-php84 + pecl mongodb) exists
#  - <worktree-dir> has vendor/ installed and .env pointed at oms-flipcheck-mysql
#    (DB_HOST/LANDLORD_HOST/REPORTING_HOST=oms-flipcheck-mysql, DB_USERNAME=testuser,
#    DB_PASSWORD=testpass, DB_DATABASE=om1_owltest, LANDLORD_DATABASE=om1_landlord_owltest,
#    REPORTING_DATABASE=om1_owltest_reporting)
#
# --log-junit path (if passed in extra args) must be RELATIVE to /app (the container's
# bind-mounted worktree root) — an absolute host path silently fails to write.

set -euo pipefail

WORKTREE="$1"; shift
LABEL="$1"; shift
EXTRA_ARGS=("$@")

NETWORK=oms-flipcheck-net
MYSQL_CONTAINER=oms-flipcheck-mysql
IMAGE=oms-unit-php84-mongo-flipcheck
MYSQL_ROOT_PASS=rootpass

DC() { docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASS" -h127.0.0.1 "$@"; }
RUN_PHP() {
  docker run --rm --network "$NETWORK" -v "$WORKTREE":/app -w /app "$IMAGE" "$@"
}

echo "=== [$LABEL] 1/6: drop + recreate DBs ==="
DC <<'SQL'
DROP DATABASE IF EXISTS om1_owltest;
DROP DATABASE IF EXISTS om1_landlord_owltest;
DROP DATABASE IF EXISTS om1_owltest_reporting;
CREATE DATABASE om1_owltest;
CREATE DATABASE om1_landlord_owltest;
CREATE DATABASE om1_owltest_reporting;
GRANT ALL PRIVILEGES ON om1_owltest.* TO 'testuser'@'%';
GRANT ALL PRIVILEGES ON om1_landlord_owltest.* TO 'testuser'@'%';
GRANT ALL PRIVILEGES ON om1_owltest_reporting.* TO 'testuser'@'%';
FLUSH PRIVILEGES;
SQL

echo "=== [$LABEL] 2/6: landlord migrate ==="
RUN_PHP php artisan migrate --database=landlord --path=database/migrations/landlord --force

echo "=== [$LABEL] 3/6: seed owltest tenant row in landlord.tenants ==="
DC om1_landlord_owltest <<'SQL'
INSERT INTO tenants (name, `database`, created_at, updated_at)
VALUES ('owltest', 'om1_owltest', NOW(), NOW())
ON DUPLICATE KEY UPDATE `database` = VALUES(`database`);
SQL

echo "=== [$LABEL] 4/6: tenant-initial baseline schema (via tenants:artisan) ==="
RUN_PHP php artisan tenants:artisan "migrate --path=database/migrations/tenant-initial --force"

echo "=== [$LABEL] 5/6: tenant migrations, drift-retry loop ==="
# Known from-scratch-migrate-only quirks (unrelated to SBDEV-3524, same on every commit):
# tenant-baseline.sql is a live snapshot, not a clean point-in-time export relative to the
# migration history, so some migrations' end states are already present in the snapshot
# before the migration that "creates" them has run. Retry loop: on any
# already-exists/duplicate-column/duplicate-key/duplicate-entry failure, mark that one
# migration as applied in the `migrations` table (tenant connection) and retry.
MAX_RETRIES=250
attempt=0
while true; do
  attempt=$((attempt+1))
  if [ "$attempt" -gt "$MAX_RETRIES" ]; then
    echo "!!! [$LABEL] exceeded $MAX_RETRIES drift-retry attempts, aborting" >&2
    exit 1
  fi
  set +e
  OUT=$(RUN_PHP php artisan tenants:artisan "migrate --path=database/migrations/tenant --force" 2>&1)
  RC=$?
  set -e
  echo "$OUT" | tail -20
  if [ "$RC" -eq 0 ]; then
    echo "=== [$LABEL] tenant migrations clean after $attempt attempt(s) ==="
    break
  fi
  # Extract the failing migration file name PHP/Artisan reports right before the SQL error,
  # e.g. "Migrating: 2025_08_20_000000_add_foo_column"
  FAILED_MIGRATION=$(echo "$OUT" | grep -oE '[0-9]{4}_[0-9]{2}_[0-9]{2}_[0-9]{6}_[A-Za-z0-9_]+' | tail -1 || true)
  if echo "$OUT" | grep -qiE "already exists|Duplicate column|Duplicate key|Duplicate entry" && [ -n "$FAILED_MIGRATION" ]; then
    echo "=== [$LABEL] marking $FAILED_MIGRATION as applied (drift) and retrying (attempt $attempt) ==="
    DC om1_owltest <<SQL
INSERT INTO migrations (migration, batch)
SELECT '$FAILED_MIGRATION', COALESCE((SELECT MAX(batch) FROM migrations), 0) + 1
WHERE NOT EXISTS (SELECT 1 FROM migrations WHERE migration = '$FAILED_MIGRATION');
SQL
    continue
  else
    echo "!!! [$LABEL] tenant migration failed with an unhandled error:" >&2
    echo "$OUT" >&2
    exit 1
  fi
done

# Pre-mark a migration known (from prior analysis) to always collide with the baseline snapshot
DC om1_owltest <<'SQL'
INSERT INTO migrations (migration, batch)
SELECT '2025_12_21_120500_add_missing_order_status_history_exception_fields', COALESCE((SELECT MAX(batch) FROM migrations), 0) + 1
WHERE NOT EXISTS (SELECT 1 FROM migrations WHERE migration = '2025_12_21_120500_add_missing_order_status_history_exception_fields');
SQL

echo "=== [$LABEL] 6/6: db:create-test-data ==="
RUN_PHP php artisan db:create-test-data

echo "=== [$LABEL] running phpunit ==="
RUN_PHP php vendor/bin/phpunit --testsuite Unit --no-coverage "${EXTRA_ARGS[@]}"
