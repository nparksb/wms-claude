#!/usr/bin/env bash
# verify-260701-wineco-replenishment-job-index-and-cadence.sh
# Machine-checkable acceptance for the plan:
#   sbdocs/1-Projects/wms1/plan/260701-wineco-replenishment-job-index-and-cadence.md
#
# Run:  bash sbdocs/9-System/scripts/verify-260701-wineco-replenishment-job-index-and-cadence.sh
# Exit code 0 iff every check passes. Paste the final "Result:" line in the completion report.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}
skip() { printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }
mvn_test_passes() {
    mvn test -Dtest="$1" -DfailIfNoTests=false -q 2>&1 \
      | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
}

MIG="src/main/resources/db/migration/V1.26.31__replenishorder_open_state_index.sql"
JOB="src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java"
MOBILE="src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java"
TEST="ReplenishmentOrderMaintenanceServiceUnitTest"
SVC="src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java"
UTEST="src/test/java/net/aim_ai/wms/unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java"

# --- Fix A: migration ---------------------------------------------------------
check_A_migration_exists()      { test -f "$MIG"; }
check_A_index_name()            { file_contains 'idx_replenishorder_open_state' "$MIG"; }
check_A_partial_predicate()     { file_contains 'WHERE[[:space:]]+state[[:space:]]*<[[:space:]]*700' "$MIG"; }
check_A_state_column()          { file_contains 'ON[[:space:]]+replenishorder[[:space:]]*\([[:space:]]*state[[:space:]]*\)' "$MIG"; }
check_A_if_not_exists()         { file_contains 'CREATE[[:space:]]+INDEX[[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS' "$MIG"; }
# Migration must NOT use CONCURRENTLY (would break Flyway 6.4 txn / startup). DBA runs that out-of-band.
# Gate on file existence so the negative check can't pass vacuously before the migration is added.
check_A_no_concurrently()       { test -f "$MIG" && file_not_contains 'CONCURRENTLY' "$MIG"; }
# Guard: the originally-proposed narrow index must not be what shipped.
check_A_not_narrow_index()      { test -f "$MIG" && file_not_contains 'destination_id[[:space:]]+IS[[:space:]]+NULL' "$MIG"; }

# --- Fix B: cron recalc honors cadence ----------------------------------------
check_B_cron_force_false()      { file_contains 'recalculateOpenOrders\(false\)' "$JOB"; }
check_B_cron_force_true_gone()  { file_not_contains 'recalculateOpenOrders\(true\)' "$JOB"; }
# Site #7 must remain immediate (force=true) — user-triggered mobile path.
check_B_mobile_unchanged()      { file_contains 'recalculateOpenOrders\(true\)' "$MOBILE"; }
# Fix B2 — cadence skip is logged (observability).
check_B2_skip_logged()          { test -f "$SVC" && file_contains 'LOG\.debug\("recalculateOpenOrders skipped' "$SVC"; }
# The cadence unit tests were actually written (not just "old suite still green").
check_T_within_cadence_test()   { test -f "$UTEST" && file_contains 'forceFalse_withinCadence_skipsQuery' "$UTEST"; }
check_T_cadence_zero_test()     { test -f "$UTEST" && file_contains 'forceFalse_cadenceZero_runsEveryTime' "$UTEST"; }

echo
echo "verify-260701-wineco-replenishment-job-index-and-cadence — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run A1  "Fix A — migration V1.26.31 exists"              check_A_migration_exists
run A2  "Fix A — index named idx_replenishorder_open_state" check_A_index_name
run A3  "Fix A — partial predicate WHERE state < 700"     check_A_partial_predicate
run A4  "Fix A — indexes the state column"                check_A_state_column
run A5  "Fix A — uses CREATE INDEX IF NOT EXISTS"         check_A_if_not_exists
run A6  "Fix A — migration does NOT use CONCURRENTLY"     check_A_no_concurrently
run A7  "Fix A — not the narrow destination_id index"     check_A_not_narrow_index
echo
run B1  "Fix B — cron calls recalculateOpenOrders(false)" check_B_cron_force_false
run B2  "Fix B — no recalculateOpenOrders(true) left in cron job" check_B_cron_force_true_gone
run B3  "Fix B — mobile path keeps recalculateOpenOrders(true)"   check_B_mobile_unchanged
run B4  "Fix B2 — cadence skip is logged (LOG.debug)"    check_B2_skip_logged
echo
run T1  "Test — within-cadence skip test was written"    check_T_within_cadence_test
run T2  "Test — cadence-zero runs-every-time test was written" check_T_cadence_zero_test
# BT is a UNIT test only (the v1 @SpringBootTest/Testcontainers IT lane is blocked — SBDEV-2384).
# It proves the maintenance-service unit suite (incl. the two new cadence tests) compiles + passes.
run BT  "Behavior — maintenance service unit test passes (unit lane only)" mvn_test_passes "$TEST"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
