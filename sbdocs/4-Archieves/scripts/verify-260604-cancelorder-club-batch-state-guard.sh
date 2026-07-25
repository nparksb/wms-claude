#!/usr/bin/env bash
# verify-260604-cancelorder-club-batch-state-guard.sh
#
# Acceptance for `260604-cancelorder-club-batch-state-guard.md` (wms2).
#
# Fix: CustomerorderService.cancelOrder gains a batch-state guard that blocks an OMS
#      cancel of a CLUB order while the batch is mid-run (527) or partially processed
#      (520/525 with a built parcel), throwing BusinessException (-> HTTP 400 WRONG_STATE).
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-260604-cancelorder-club-batch-state-guard.sh
#   $ SKIP_MVN=1 bash sbdocs/9-System/scripts/verify-260604-cancelorder-club-batch-state-guard.sh

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { ! grep -qE "$1" "$2" 2>/dev/null; }
file_contains_ml() {
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null
}

SVC=src/main/java/net/aim_ai/wms/service
COS=$SVC/CustomerorderService.java

echo
echo "verify-260604-cancelorder-club-batch-state-guard — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- S1 — guard helper present, club-scoped, locked read (plan §3.1) ----------
# Implemented as the sentinel form the plan suggested: a single-lookup helper
# clubRunCancellationBlockingState(...) returning the blocking state or null.

run S1a "S1 — clubRunCancellationBlockingState helper present" \
    file_contains 'clubRunCancellationBlockingState\s*\(' "$COS"
run S1b "S1 — helper takes the batch under findByIdForUpdate (serializes vs ClubLine)" \
    file_contains_ml 'clubRunCancellationBlockingState[\s\S]{0,400}findByIdForUpdate' "$COS"
run S1c "S1 — helper gated on OrderBatchType.CLUB" \
    file_contains_ml 'clubRunCancellationBlockingState[\s\S]{0,600}OrderBatchType\.CLUB' "$COS"
run S1d "S1 — helper checks CLUB_RUN_IN_PROGRESS state" \
    file_contains 'ORDER_BATCH_CLUB_RUN_IN_PROGRESS' "$COS"
run S1e "S1 — helper checks ACTIVATED/STAGING + parcelId-built condition" \
    file_contains_ml 'ORDER_BATCH_ACTIVATED[\s\S]{0,200}ORDER_BATCH_STAGING_LANE_ASSIGNED[\s\S]{0,200}getParcelId\(\)\s*!=\s*null' "$COS"

echo

# --- S2 — guard wired into cancelOrder ----------------------------------------
# (Placement — after already-cancelled, before position cancellation — is asserted
#  behaviorally by CustomerorderServiceUnitTest, not by brittle line-order greps.)

run S2a "S2 — cancelOrder invokes the guard helper at a call site" \
    file_contains '=\s*clubRunCancellationBlockingState\(' "$COS"
run S2b "S2 — block throws the club-batch-state rejection message" \
    file_contains 'while its club batch is in state' "$COS"

echo

# --- Targeted unit test -------------------------------------------------------
mvn_test_passes() {
    local cls=$1
    mvn test -Dtest="$cls" -DfailIfNoTests=false >/dev/null 2>&1
}

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-COS "T — CustomerorderServiceUnitTest passes" mvn_test_passes CustomerorderServiceUnitTest
else
    skip T-mvn "Targeted unit-test run" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
