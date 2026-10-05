#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/omsenv.sh"
DC <<'SQL'
DROP DATABASE IF EXISTS om1_owltest; DROP DATABASE IF EXISTS om1_landlord_owltest; DROP DATABASE IF EXISTS om1_owltest_reporting;
CREATE DATABASE om1_owltest; CREATE DATABASE om1_landlord_owltest; CREATE DATABASE om1_owltest_reporting;
SQL
RUN_PHP php artisan migrate --database=landlord --path=database/migrations/landlord --force 2>&1 | tail -3
DC om1_landlord_owltest <<'SQL'
INSERT INTO tenants (name, `database`, created_at, updated_at) VALUES ('owltest', 'om1_owltest', NOW(), NOW());
SQL
RUN_PHP php artisan migrate --database=testing_reporting --path=database/migrations/tenant-reporting --force 2>&1 | tail -3
RUN_PHP php artisan tenants:artisan "migrate --path=database/migrations/tenant-initial --force" 2>&1 | tail -3
for attempt in $(seq 1 250); do
  OUT=$(RUN_PHP php artisan tenants:artisan "migrate --path=database/migrations/tenant --force" 2>&1); RC=$?
  if [ $RC -eq 0 ] && ! echo "$OUT" | grep -qiE "SQLSTATE|FAIL"; then echo "tenant migrations clean after $attempt"; echo "$OUT" | tail -3; break; fi
  F=$(echo "$OUT" | grep -oE '[0-9]{4}_[0-9]{2}_[0-9]{2}_[0-9]{6}_[A-Za-z0-9_]+' | tail -1)
  if echo "$OUT" | grep -qiE "already exists|Duplicate column|Duplicate key|Duplicate entry|check that column/key exists|Can't DROP" && [ -n "$F" ]; then
    echo "drift: marking $F"
    DC om1_owltest -e "INSERT INTO migrations (migration, batch) SELECT '$F', COALESCE((SELECT MAX(batch) FROM migrations m),0)+1 WHERE NOT EXISTS (SELECT 1 FROM migrations WHERE migration='$F');"
  else echo "UNHANDLED:"; echo "$OUT" | tail -30; exit 1; fi
done
RUN_PHP php artisan db:create-test-data 2>&1 | tail -3
DC -e "SELECT table_schema, count(*) FROM information_schema.tables WHERE table_schema LIKE 'om1%' GROUP BY 1;"
